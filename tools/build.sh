#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
set -CeEuo pipefail
IFS=$'\n\t'
trap -- 's=$?; printf >&2 "%s\n" "${0##*/}:${LINENO}: \`${BASH_COMMAND}\` exit with ${s}"; exit ${s}' ERR
trap -- 'printf >&2 "%s\n" "${0##*/}: trapped SIGINT"; exit 1' SIGINT
cd -- "$(dirname -- "$0")"/..

# USAGE:
#    ./tools/build.sh [+toolchain] [target]...

default_targets=(
  # no atomic load/store in core (16-bit)
  msp430-none-elf

  # no atomic CAS in core (16-bit)
  avr-none
  # no atomic CAS (32-bit)
  thumbv6m-none-eabi
  riscv32i-unknown-none-elf

  # no-std
  thumbv7m-none-eabi
  # riscv32 with atomic
  riscv32imac-unknown-none-elf
  riscv32imc-esp-espidf
)

x() {
  (
    set -x
    "$@"
  )
}
x_cargo() {
  if [[ -n "${RUSTFLAGS:-}" ]]; then
    printf '%s\n' "+ RUSTFLAGS='${RUSTFLAGS}' \\"
  fi
  x cargo "$@"
  printf '\n'
}
retry() {
  for i in {1..10}; do
    if "$@"; then
      return 0
    else
      sleep "${i}"
    fi
  done
  "$@"
}
bail() {
  printf >&2 'error: %s\n' "$*"
  exit 1
}
info() {
  printf >&2 'info: %s\n' "$*"
}
is_no_std() {
  case "$1" in
    *-linux-none*) ;;
    # https://github.com/rust-lang/rust/blob/1.84.0/library/std/build.rs#L65
    # ESP-IDF and AIX supports std, but they are often broken.
    # aarch64-unknown-linux-uclibc is a custom target and libc/std currently doesn't support it.
    *-none* | *-psp* | *-psx* | *-cuda* | avr* | *-espidf | *-aix | aarch64-unknown-linux-uclibc) return 0 ;;
  esac
  return 1
}

pre_args=()
if [[ "${1:-}" == "+"* ]]; then
  pre_args+=("$1")
  shift
fi
if [[ $# -gt 0 ]]; then
  targets=("$@")
else
  targets=("${default_targets[@]}")
fi

rustup_target_list=$(rustup ${pre_args[@]+"${pre_args[@]}"} target list | cut -d' ' -f1)
rustc_target_list=$(rustc ${pre_args[@]+"${pre_args[@]}"} --print target-list)
rustc_version=$(rustc ${pre_args[@]+"${pre_args[@]}"} -vV | grep -E '^release:' | cut -d' ' -f2)
rustc_minor_version="${rustc_version#*.}"
rustc_minor_version="${rustc_minor_version%%.*}"
llvm_version=$(rustc ${pre_args[@]+"${pre_args[@]}"} -vV | { grep -E '^LLVM version:' || true; } | cut -d' ' -f3)
llvm_version="${llvm_version%%.*}"
base_args=(${pre_args[@]+"${pre_args[@]}"} hack build)
nightly=''
if [[ "${rustc_version}" =~ nightly|dev ]]; then
  nightly=1
  retry rustup ${pre_args[@]+"${pre_args[@]}"} component add rust-src &>/dev/null
fi

build() {
  local target="$1"
  shift
  local args=("${base_args[@]}" --target "${target}")
  local target_rustflags="${RUSTFLAGS:-}"
  if ! grep -Eq "^${target}$" <<<"${rustc_target_list}"; then
    if [[ "${target}" == "avr-none" ]]; then
      target=avr-unknown-gnu-atmega328 # before https://github.com/rust-lang/rust/pull/131651
    else
      if [[ -n "${ALL_TARGETS_MUST_BE_AVAILABLE:-}" ]]; then
        bail "target '${target}' not available on ${rustc_version}"
      fi
      info "target '${target}' not available on ${rustc_version} (skipped all checks)"
      return 0
    fi
  fi
  if grep -Eq "^${target}$" <<<"${rustup_target_list}"; then
    retry rustup ${pre_args[@]+"${pre_args[@]}"} target add "${target}" &>/dev/null
  elif [[ -n "${nightly}" ]]; then
    if is_no_std "${target}"; then
      args+=(-Z build-std="core,alloc")
    else
      args+=(-Z build-std)
    fi
  else
    info "target '${target}' requires nightly compiler (skipped all checks)"
    return 0
  fi
  local cfgs
  cfgs=$(RUSTC_BOOTSTRAP=1 rustc ${pre_args[@]+"${pre_args[@]}"} --print cfg --target "${target}")
  local has_atomic_cas=1
  # target_has_atomic changed in 1.40.0-nightly: https://github.com/rust-lang/rust/pull/65214
  if [[ "${rustc_minor_version}" -ge 40 ]]; then
    if ! grep -Eq '^target_has_atomic=' <<<"${cfgs}"; then
      has_atomic_cas=''
    fi
  else
    if ! grep -Eq '^target_has_atomic="cas"' <<<"${cfgs}"; then
      has_atomic_cas=''
    fi
  fi
  case "${target}" in
    avr*)
      if [[ "${llvm_version}" -eq 16 ]]; then
        # https://github.com/rust-lang/compiler-builtins/issues/523
        target_rustflags+=" -C linker-plugin-lto -C codegen-units=1"
      elif [[ "${llvm_version}" -ge 17 ]]; then
        # https://github.com/rust-lang/rust/issues/88252
        target_rustflags+=" -C opt-level=s"
      fi
      if [[ "${target}" == "avr-none" ]]; then
        # "error: target requires explicitly specifying a cpu with `-C target-cpu`"
        target_rustflags+=" -C target-cpu=atmega328p"
      fi
      ;;
  esac

  if is_no_std "${target}"; then
    args+=(--exclude-features std)
    if [[ -z "${has_atomic_cas}" ]]; then
      case "${target}" in
        avr* | msp430*) ;; # always single-core
        *) target_rustflags+=' --cfg portable_atomic_unsafe_assume_single_core' ;;
      esac
    fi
  fi

  RUSTFLAGS="${target_rustflags}" \
    x_cargo "${args[@]}" --feature-powerset --optional-deps --no-dev-deps --manifest-path Cargo.toml
}

for target in "${targets[@]}"; do
  build "${target}"
done
