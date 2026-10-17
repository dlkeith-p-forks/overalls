use super::*;

#[test]
fn request_constants_match_the_kernel_uapi() {
    // KVMIO is 0xAE; _IOC_NONE: dir bits carry no size, so requests are the
    // type-shifted base plus the nr. Verified against linux/kvm.h.
    assert_eq!(KVM_GET_API_VERSION, 0xAE00);
    assert_eq!(KVM_CREATE_VM, 0xAE01);
    assert_eq!(REQUIRED_API_VERSION, 12);
    assert_eq!(KVM_DEVICE, "/dev/kvm");
}
