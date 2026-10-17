{ pkgs }:
# @cc [owner:ghuntley,label:verification] native-vsock-core-properties
# The actual core linked into both guest kernels MUST pass malformed frame,
# unchanged-on-refusal, bounded credit, directional shutdown and counter-wrap
# vectors, with generated transitions and address/undefined-behavior sanitizers.
pkgs.runCommand "native-vsock-core-properties" {
  nativeBuildInputs = [ pkgs.llvmPackages_19.clang ];
} ''
  cp ${./ov_vsock.h} ov_vsock.h
  cp ${./ov_vsock.c} ov_vsock.c
  for suite in ${./ov_vsock_test.c} ${./ov_vsock_direction_test.c}; do
    clang -std=c11 -pedantic -Wall -Wextra -Werror -O1 -g \
      -fsanitize=address,undefined -fno-omit-frame-pointer \
      -I. ov_vsock.c "$suite" -o suite
    ./suite
  done
  mkdir "$out"
  printf '%s\n' 'Shared parser and credit properties passed; no native runtime claim.' > "$out/result"
''
