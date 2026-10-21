use hegel::{generators as gs, TestCase};
use mila_runtime::{
    AttachError, AttachHeader, AttachMode, AttachOutcome, AttachPhase, TerminalAttach,
    MAXIMUM_ATTACH_ATTEMPTS,
};

#[hegel::test(test_cases = 128)]
fn arbitrary_channel_interleavings_preserve_authority(tc: TestCase) {
    let actions = tc.draw(gs::vecs(gs::default::<u8>()).max_size(300));
    let mut state = TerminalAttach::initial();
    for action in actions {
        let before = state;
        let generation = state.generation();
        match action % 12 {
            0 => {
                state.request();
            }
            1 | 2 => {
                state.header(
                    generation,
                    Some(AttachHeader::Attached {
                        from: u64::from(action),
                        mode: if action % 2 == 0 {
                            AttachMode::ReadOnly
                        } else {
                            AttachMode::ReadWrite
                        },
                    }),
                );
            }
            3 => {
                state.output(generation, usize::from(action));
            }
            4 => {
                state.ended(generation, AttachOutcome::Transport);
            }
            5 => {
                state.ended(generation, AttachOutcome::Authority);
            }
            6 => state.set_read_only(true),
            7 => state.set_read_only(false),
            8 => state.screen_reset(),
            9 => state.detach(),
            10 => {
                state.header(generation, None);
            }
            _ => {
                state.header(
                    generation,
                    Some(AttachHeader::Refused(AttachError::Forbidden)),
                );
            }
        }
        assert_eq!(state.can_resize(), state.can_send_input());
        assert_eq!(
            state.can_send_input(),
            state.phase() == AttachPhase::Attached
                && state.mode() == Some(AttachMode::ReadWrite)
                && !state.read_only_requested()
        );
        if before.phase() != AttachPhase::Attached && action % 12 == 3 {
            assert_eq!(state, before);
        }
        // Events from both a previous and a future channel must be inert.
        for stale in [state.generation().wrapping_sub(1), state.generation() + 1] {
            let saved = state;
            assert!(!state.header(
                stale,
                Some(AttachHeader::Attached {
                    from: 0,
                    mode: AttachMode::ReadWrite
                })
            ));
            assert!(!state.output(stale, 50));
            assert!(!state.ended(stale, AttachOutcome::Transport));
            assert_eq!(state, saved);
        }
    }
}

#[hegel::test(test_cases = 64)]
fn resume_jump_and_retry_budget(tc: TestCase) {
    let cursor = u64::from(tc.draw(gs::default::<u32>()));
    let mut state = TerminalAttach::initial();
    assert_eq!(state.resume_cursor(), None);
    state.request();
    state.connected(state.generation(), cursor);
    assert!(!state.reset_pending());
    state.output(state.generation(), 10);
    state.ended(state.generation(), AttachOutcome::Transport);
    assert_eq!(state.resume_cursor(), Some(cursor + 10));
    state.request();
    state.connected(state.generation(), cursor);
    assert!(state.reset_pending());
    assert_eq!(state.jumps(), 1);
    state.screen_reset();
    assert!(!state.reset_pending());
    for attempt in 1..=MAXIMUM_ATTACH_ATTEMPTS {
        state.ended(state.generation(), AttachOutcome::Transport);
        assert_eq!(state.attempts(), attempt);
        assert_eq!(
            state.phase(),
            if attempt < MAXIMUM_ATTACH_ATTEMPTS {
                AttachPhase::Waiting
            } else {
                AttachPhase::Ended
            }
        );
        if attempt < MAXIMUM_ATTACH_ATTEMPTS {
            state.request();
        }
    }
    state.request();
    assert_eq!(state.attempts(), 0);
    state.header(
        state.generation(),
        Some(AttachHeader::Attached {
            from: cursor,
            mode: AttachMode::ReadOnly,
        }),
    );
    state.set_read_only(false);
    assert!(!state.can_send_input());
    state.ended(state.generation(), AttachOutcome::Closed);
    assert_eq!(state.phase(), AttachPhase::Ended);
}
