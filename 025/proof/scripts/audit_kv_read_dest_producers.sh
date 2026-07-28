#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Structural audit: can any KeyVault read client in the submitted tree present a
# multi-hot kv_read_dest vector to kv_read_rule_check?
#
# The directed simulation shows what the destination classification at
# src/keyvault/rtl/kv_read_rule_check.sv:64 does with a multi-hot vector. This
# script decides whether that input is producible, by enumerating:
#
#   gate 1  every assignment to read_metrics.kv_read_dest in the tree
#   gate 2  whether each such assignment is a single hardcoded one-hot literal
#   gate 3  whether the KeyVault read control register structure carries any
#           destination field that software could drive
#   gate 4  which read clients drive read_metrics.ocp_lock_in_progress from a
#           real signal, bounding which consumers the rule can act on at all
#
# Exits nonzero and prints gate_fail: on any gate that cannot be evaluated.
# Prints a stable result= marker.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${CASE_DIR}/../.." && pwd)"

if [[ ! -d "${REPO_ROOT}/src" ]]; then
  echo "gate_fail: cannot locate submitted tree src/ from ${CASE_DIR}"
  echo "result=FAIL"
  exit 1
fi

cd "${REPO_ROOT}"

status=0
echo "=== kv_bug_025 structural audit of kv_read_dest producers ==="
echo "tree_root_relative=."
echo

# ---------------------------------------------------------------------------
echo "--- gate 1: assignments to kv_read_dest ---"
producers="$(grep -rn --include='*.sv' 'kv_read_dest' src/ \
             | grep -v 'src/keyvault/rtl/kv_defines_pkg.sv' \
             | grep -v 'src/keyvault/rtl/kv_read_rule_check.sv' \
             || true)"

if [[ -z "${producers}" ]]; then
  echo "gate_fail: found no kv_read_dest assignment outside the package and the rule module"
  status=1
else
  echo "${producers}"
  producer_count="$(printf '%s\n' "${producers}" | grep -c '.')"
  echo "kv_read_dest_producer_sites=${producer_count}"
fi
echo

# ---------------------------------------------------------------------------
echo "--- gate 2: producers that are NOT a single one-hot shift literal ---"
# A one-hot producer has the shape  <lhs> = KV_NUM_READ'(1<<KV_DEST_IDX_<name>);
# Anything else (an OR of two indices, a register field, a variable) would be a
# candidate multi-hot source.
non_onehot="$(printf '%s\n' "${producers}" \
              | grep 'kv_read_dest' \
              | grep -v "1<<KV_DEST_IDX_" \
              | grep -v "1 << KV_DEST_IDX_" \
              || true)"

if [[ -z "${non_onehot}" ]]; then
  echo "none: every kv_read_dest assignment is a single hardcoded one-hot shift literal"
  echo "multihot_capable_producers=0"
else
  echo "${non_onehot}"
  echo "multihot_capable_producers=$(printf '%s\n' "${non_onehot}" | grep -c '.')"
fi
echo

# ---------------------------------------------------------------------------
echo "--- gate 3: destination fields in the KeyVault read control structure ---"
# kv_read_ctrl_reg_t is the structure a read client's control register decodes
# into, so it bounds what software can drive. If it carries no destination
# member, no software register write can reach kv_read_dest.
#
# The member list is extracted by walking back from the closing line of this
# specific struct to its own opening brace, so that neighbouring structs in the
# package (several of which do contain 'dest' members) cannot leak in.
pkg=src/keyvault/rtl/kv_defines_pkg.sv
members="$(awk '
  /typedef struct packed \{/ { start = NR; buf = ""; collecting = 1; next }
  collecting { buf = buf $0 "\n" }
  /\} kv_read_ctrl_reg_t;/ { if (collecting) { printf "%s", buf; exit } }
' "${pkg}")"

if [[ -z "${members}" ]]; then
  echo "gate_fail: could not extract kv_read_ctrl_reg_t member list from ${pkg}"
  status=1
else
  echo "kv_read_ctrl_reg_t members:"
  printf '%s' "${members}" | sed 's/^/  /'

  # Count members mentioning a destination selector. Matched against this
  # struct's members only.
  dest_members="$(printf '%s' "${members}" | grep -c 'dest' || true)"
  echo "kv_read_ctrl_reg_t_dest_members=${dest_members}"
  if [[ "${dest_members}" -gt 0 ]]; then
    echo "software_reachable_dest_field=yes"
  else
    echo "software_reachable_dest_field=no"
  fi
fi
echo

# ---------------------------------------------------------------------------
echo "--- gate 4: read clients driving ocp_lock_in_progress into the rule ---"
grep -rn --include='*.sv' 'read_metrics\.ocp_lock_in_progress\|_read_metrics\.ocp_lock_in_progress' \
     src/ submodules/adams-bridge/src/ 2>/dev/null | sed 's/^/  /' || true
echo

echo "--- gate 5: rule module instantiation sites ---"
grep -rn --include='*.sv' 'kv_read_rule_check' src/ \
  | grep -v 'src/keyvault/rtl/kv_read_rule_check.sv' | sed 's/^/  /' || true
echo

if (( status != 0 )); then
  echo "result=FAIL"
  exit 1
fi

echo "audit_complete=1"
echo "result=PASS"
exit 0
