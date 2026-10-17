use super::*;
use hegel::generators as gs;
use hegel::TestCase;

/// @cc [owner:ghuntley,label:verification] hegel-flow-selectors
/// Generated address/port inputs MUST match the independent canonical models:
/// dotted-quad IPv4 with strict round-trip, and decimal ports without leading
/// zeros within 1..=65535; nothing else selects.
#[hegel::test]
fn address_and_port_selectors_are_canonical(tc: TestCase) {
    let address_candidates = [
        "127.0.0.1",
        "10.0.0.1",
        "256.0.0.1",
        "1.2.3.4 ",
        "01.2.3.4",
        "1.2.3.4.5",
        "192.168.0.1",
        "",
        "1..2.3",
        "a.b.c.d",
    ];
    let port_candidates = [
        "0", "00", "01", "1", "80", "443", "65535", "65536", "655350", "x", "", "-1", " 80",
    ];
    let addr_text = tc.draw(gs::sampled_from(&address_candidates)).to_string();
    let port_text = tc.draw(gs::sampled_from(&port_candidates)).to_string();

    let addr_spec = (|| {
        let segments: Vec<&str> = addr_text.split('.').collect();
        if segments.len() != 4 {
            return false;
        }
        let mut any = [0_u8; 4];
        for (index, segment) in segments.iter().enumerate() {
            if segment.is_empty()
                || (segment.len() > 1 && segment.starts_with('0'))
                || !segment.bytes().all(|b| b.is_ascii_digit())
            {
                return false;
            }
            let Ok(value) = segment.parse::<u16>() else {
                return false;
            };
            if value > 255 {
                return false;
            }
            any[index] = value as u8;
        }
        addr_text == format!("{}.{}.{}.{}", any[0], any[1], any[2], any[3])
    })();
    let port_spec = !port_text.is_empty()
        && port_text.len() <= 5
        && !port_text.starts_with('0')
        && port_text.bytes().all(|b| b.is_ascii_digit())
        && port_text
            .parse::<u32>()
            .is_ok_and(|v| (1..=65535).contains(&v));

    assert_eq!(
        address(OsStr::new(&addr_text)).is_some(),
        addr_spec,
        "{addr_text:?}"
    );
    assert_eq!(
        port(OsStr::new(&port_text)).is_some(),
        port_spec,
        "{port_text:?}"
    );
}

/// @cc [owner:ghuntley,label:verification] flow-selector-wire-layout
/// A selected tuple MUST reach conntrack in network byte order, exactly as
/// inet_pton and htons lay it out in memory, for every address and port.
#[hegel::test]
fn selected_tuple_uses_network_byte_order_in_memory(tc: TestCase) {
    let octets = [
        tc.draw(gs::integers::<u8>()),
        tc.draw(gs::integers::<u8>()),
        tc.draw(gs::integers::<u8>()),
        tc.draw(gs::integers::<u8>()),
    ];
    let text = format!("{}.{}.{}.{}", octets[0], octets[1], octets[2], octets[3]);
    let value = address(OsStr::new(&text)).expect("canonical address");
    assert_eq!(value.to_ne_bytes(), octets, "{text}");

    let number = tc.draw(gs::integers::<u16>().min_value(1));
    let value = port(OsStr::new(&number.to_string())).expect("canonical port");
    assert_eq!(value.to_ne_bytes(), number.to_be_bytes(), "{number}");
}

#[hegel::test]
fn label_bit_endianness_matches_the_repr_spec(tc: TestCase) {
    // Mark bits through the same shape the kernel callback uses, then check
    // the exact hex network-order rendering used on the wire.
    let mut label = Labels::zero();
    let bit = tc.draw(gs::integers::<u32>().min_value(0).max_value(127));
    label.0[15 - (bit / 8) as usize] |= 1 << (bit % 8);
    let mut expected = [0_u8; 16];
    expected[15 - (bit / 8) as usize] |= 1 << (bit % 8);
    assert_eq!(label, Labels(expected));
    let hex = label.to_hex();
    assert_eq!(hex.len(), 32);
    assert!(hex.bytes().all(|b| b.is_ascii_hexdigit()));
    let hexstr = &hex[..2 * (15 - (bit / 8) as usize) + 2];
    let decoded = u8::from_str_radix(hexstr, 16).expect("hex pair");
    assert_eq!(decoded, 1 << (bit % 8));
}

#[hegel::test]
fn cli_selector_matrix_matches_oracle(tc: TestCase) {
    let args = [
        "127.0.0.1",
        "10.0.0.1",
        "1.2.3.4",
        "bad",
        "",
        "65535",
        "1",
        "0",
        "443",
    ];
    let count = tc.draw(gs::integers::<usize>().min_value(0).max_value(6));
    let vec: Vec<OsString> = (0..count)
        .map(|_| OsString::from(tc.draw(gs::sampled_from(&args))))
        .collect();
    let expected = if vec.len() == 4 {
        let [s, sp, d, dp]: &[OsString] = &vec[..] else {
            unreachable!("length is checked")
        };
        address(s).is_some() && port(sp).is_some() && address(d).is_some() && port(dp).is_some()
    } else {
        false
    };
    assert_eq!(parse_cli(&vec).is_some(), expected, "argv {vec:?}");
}
