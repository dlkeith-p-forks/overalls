//! Generated pure byte-history checks; these do not establish PTY or vsock isolation.
use crate::{frame, ring::Ring};
use hegel::{generators as gs, TestCase};

/// @cc [owner:ghuntley,label:verification;recovery] terminal-ring-history-oracle
/// Every append/resize prefix MUST retain exactly the untruncated suffix of the
/// original byte history; cursor replay MUST report the actual gap and MUST NOT
/// recreate bytes discarded before a later capacity increase.
#[hegel::test]
fn ring_resize_and_cursor_histories(tc: TestCase) {
  let mut zero_capacity = Ring::new(0);
  assert_eq!(zero_capacity.capacity(), 1);
  zero_capacity.push(&[7, 9]);
  assert_eq!(zero_capacity.replay_from(0), (1, vec![9]));
  zero_capacity.set_capacity(0);
  assert_eq!(zero_capacity.capacity(), 1);
  assert_eq!(zero_capacity.replay_from(0), (1, vec![9]));
  let menu = [0_usize, 1, 2, 7, 8, 9, 31, 32, 33, 255, 256, 257];
  let mut ring = Ring::new(8);
  let mut history: Vec<u8> = Vec::new();
  let mut first_retained: usize = 0;
  let mut capacity: usize = 8;
  let steps = tc.draw(gs::integers::<usize>().min_value(1).max_value(64));
  for _ in 0..steps {
    if tc.draw(gs::booleans()) {
      let requested = tc.draw(gs::sampled_from(&menu));
      capacity = requested.max(1);
      ring.set_capacity(requested);
    } else {
      let count = tc.draw(gs::sampled_from(&menu));
      let bytes: Vec<u8> = tc.draw(
        gs::vecs(gs::integers::<u8>())
          .min_size(count)
          .max_size(count),
      );
      history.extend_from_slice(&bytes);
      ring.push(&bytes);
    }
    first_retained = first_retained.max(history.len().saturating_sub(capacity));
    let tail = u64::try_from(history.len()).expect("bounded history");
    let base = u64::try_from(first_retained).expect("bounded history");
    assert_eq!(ring.capacity(), capacity);
    assert_eq!(ring.base(), base);
    assert_eq!(ring.tail(), tail);
    let generated = tc.draw(gs::integers::<u64>().min_value(0).max_value(tail + 1));
    for cursor in [
      0,
      base.saturating_sub(1),
      base,
      tail.saturating_sub(1),
      tail,
      tail + 1,
      generated,
    ] {
      let start = cursor.max(base).min(tail);
      let expected = &history[usize::try_from(start).expect("bounded cursor")..];
      assert_eq!(ring.replay_from(cursor), (start, expected.to_vec()));
    }
  }
}

/// @cc [owner:ghuntley,label:verification;protocol] terminal-stream-frame-chunking
/// Splitting or coalescing valid frame bytes MUST preserve their exact payload
/// order. Parsing one frame MUST leave the next frame untouched; partial input
/// MUST remain available until its frame becomes complete.
#[hegel::test]
fn concatenated_frames_survive_arbitrary_chunk_boundaries(tc: TestCase) {
  let sizes = [
    0_usize,
    1,
    2,
    3,
    4,
    5,
    frame::MAX_PAYLOAD - 1,
    frame::MAX_PAYLOAD,
  ];
  let count = tc.draw(gs::integers::<usize>().min_value(1).max_value(4));
  let mut expected: Vec<(u8, Vec<u8>)> = Vec::new();
  let mut wire: Vec<u8> = Vec::new();
  for _ in 0..count {
    let op = tc.draw(gs::integers::<u8>());
    let size = tc.draw(gs::sampled_from(&sizes));
    let payload: Vec<u8> = tc.draw(gs::vecs(gs::integers::<u8>()).min_size(size).max_size(size));
    let encoded = frame::encode(op, &payload);
    let declared = u16::try_from(size).expect("bounded frame").to_be_bytes();
    assert_eq!(&encoded[..4], &[frame::MAGIC, op, declared[0], declared[1]]);
    assert_eq!(&encoded[4..], payload.as_slice());
    wire.extend_from_slice(&encoded);
    expected.push((op, payload));
  }
  let mut buffer: Vec<u8> = Vec::new();
  let mut offset: usize = 0;
  let mut index: usize = 0;
  while offset < wire.len() {
    let chunk = tc.draw(gs::sampled_from(&[
      1_usize, 2, 3, 4, 5, 4095, 4096, 4097, 8196,
    ]));
    let end = (offset + chunk).min(wire.len());
    buffer.extend_from_slice(&wire[offset..end]);
    offset = end;
    loop {
      let before = buffer.clone();
      match frame::decode(&buffer) {
        None => {
          if let Some((_, payload)) = expected.get(index) {
            assert!(
              buffer.len() < 4 + payload.len(),
              "complete expected frame was not decoded"
            );
          } else {
            assert!(buffer.is_empty(), "unexpected trailing stream bytes");
          }
          break;
        }
        Some(Err(())) => panic!("valid generated stream rejected"),
        Some(Ok(decoded)) => {
          let (op, payload) = expected.get(index).expect("no extra frame");
          assert_eq!(decoded.op, *op);
          assert_eq!(&decoded.payload, payload);
          let consumed = frame::consumed(payload.len());
          assert_eq!(consumed, 4 + payload.len());
          buffer.drain(..consumed);
          assert_eq!(buffer.as_slice(), &before[consumed..]);
          index += 1;
        }
      }
    }
  }
  assert_eq!(index, expected.len());
  assert!(buffer.is_empty());
}

/// @cc [owner:ghuntley,label:verification;capacity] terminal-ring-configured-boundaries
/// Filling around the configured default and maximum ring capacities MUST
/// preserve the exact retained byte suffix through shrink/grow and a later
/// append. These pure checks MUST NOT establish the shared session budget.
#[hegel::test(test_cases = 4)]
fn configured_ring_capacity_families(tc: TestCase) {
  let config = crate::session::Config::default();
  let seed = tc.draw(gs::integers::<u8>());
  for limit in [config.ring_default, config.ring_max] {
    for size in [limit - 1, limit, limit + 1] {
      let mut ring = Ring::new(limit);
      let mut history: Vec<u8> = (0..size)
        .map(|index| seed.wrapping_add(u8::try_from(index % 251).expect("bounded byte")))
        .collect();
      ring.push(&history);
      let mut first_retained = size.saturating_sub(limit);
      let resized = tc.draw(gs::sampled_from(&[1_usize, limit - 1, limit, limit + 1]));
      ring.set_capacity(resized);
      first_retained = first_retained.max(size.saturating_sub(resized));
      let extra = [seed ^ 0xff, 0, seed];
      ring.push(&extra);
      history.extend_from_slice(&extra);
      first_retained = first_retained.max(history.len().saturating_sub(resized));
      let base = u64::try_from(first_retained).expect("bounded base");
      let tail = u64::try_from(history.len()).expect("bounded tail");
      assert_eq!(ring.capacity(), resized);
      assert_eq!(ring.base(), base);
      assert_eq!(ring.tail(), tail);
      for cursor in [
        0,
        base.saturating_sub(1),
        base,
        base + 1,
        tail - 1,
        tail,
        tail + 1,
      ] {
        let start = cursor.max(base).min(tail);
        assert_eq!(
          ring.replay_from(cursor),
          (
            start,
            history[usize::try_from(start).expect("bounded cursor")..].to_vec()
          )
        );
      }
    }
  }
}

/// @cc [owner:ghuntley,label:verification;recovery] terminal-ring-fixed-shrink-grow
/// Growing after explicit truncation MUST NOT restore discarded bytes, and a
/// subsequent append MUST preserve the surviving old suffix before new bytes.
#[hegel::test(test_cases = 16)]
fn fixed_shrink_grow_preserves_only_surviving_bytes(tc: TestCase) {
  let original: Vec<u8> = tc.draw(gs::vecs(gs::integers::<u8>()).min_size(17).max_size(17));
  let extra: Vec<u8> = tc.draw(gs::vecs(gs::integers::<u8>()).min_size(3).max_size(3));
  let mut ring = Ring::new(8);
  ring.push(&original);
  assert_eq!(ring.base(), 9);
  ring.set_capacity(2);
  assert_eq!(ring.base(), 15);
  ring.set_capacity(16);
  assert_eq!(ring.base(), 15);
  assert_eq!(ring.replay_from(0), (15, original[15..].to_vec()));
  ring.push(&extra);
  let history: Vec<u8> = original.into_iter().chain(extra).collect();
  assert_eq!(ring.base(), 15);
  assert_eq!(ring.tail(), 20);
  for cursor in [0_u64, 14, 15, 16, 17, 18, 19, 20, 21] {
    let start = cursor.clamp(15, 20);
    assert_eq!(
      ring.replay_from(cursor),
      (
        start,
        history[usize::try_from(start).expect("bounded cursor")..].to_vec()
      )
    );
  }
}

/// @cc [owner:ghuntley,label:verification;protocol] terminal-frame-header-refusals
/// Partial headers MUST remain incomplete. Once a full header is present, bad
/// magic or a declared payload above MAX_PAYLOAD MUST refuse without waiting
/// for payload bytes, regardless of following data.
#[hegel::test]
fn malformed_frame_headers_refuse_before_payload(tc: TestCase) {
  let op = tc.draw(gs::integers::<u8>());
  let magic_index = tc.draw(gs::integers::<u8>().max_value(u8::MAX - 1));
  let bad_magic = if magic_index >= frame::MAGIC {
    magic_index + 1
  } else {
    magic_index
  };
  let oversized = tc.draw(
    gs::integers::<u16>()
      .min_value(u16::try_from(frame::MAX_PAYLOAD + 1).expect("bounded ceiling"))
      .max_value(u16::MAX),
  );
  let declared = oversized.to_be_bytes();
  for header in [
    [bad_magic, op, 0, 0],
    [frame::MAGIC, op, declared[0], declared[1]],
    [frame::MAGIC, op, 0xff, 0xff],
  ] {
    for length in 0..4 {
      assert_eq!(frame::decode(&header[..length]), None);
    }
    assert_eq!(frame::decode(&header), Some(Err(())));
    let mut with_trailing = header.to_vec();
    let trailing: Vec<u8> = tc.draw(gs::vecs(gs::integers::<u8>()).max_size(32));
    with_trailing.extend_from_slice(&trailing);
    assert_eq!(frame::decode(&with_trailing), Some(Err(())));
  }
}
