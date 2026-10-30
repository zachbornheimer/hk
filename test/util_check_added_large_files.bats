#!/usr/bin/env bats

setup() {
    load 'test_helper/common_setup'
    _common_setup
}
teardown() {
    _common_teardown
}

_write_config() {
    cat > hk.pkl <<HK
amends "$PKL_PATH/Config.pkl"
import "$PKL_PATH/Builtins.pkl"

hooks {
    ["check"] {
        steps {
            ["large-files"] = Builtins.check_added_large_files
        }
    }
}
HK
}

@test "check_added_large_files builtin - fails on a large file containing NUL bytes" {
    _write_config
    # 501 KiB of NUL bytes: hk's default binary filter would drop this file.
    dd if=/dev/zero of=big.bin bs=1024 count=501 2>/dev/null
    git add -A

    run hk check
    assert_failure
    assert_output --partial "big.bin"
}

@test "check_added_large_files builtin - fails on a large text file" {
    _write_config
    yes "some text line" | head -c 513000 > big.txt
    git add -A

    run hk check
    assert_failure
    assert_output --partial "big.txt"
}

@test "check_added_large_files builtin - passes on a small binary file" {
    _write_config
    dd if=/dev/zero of=small.bin bs=1024 count=1 2>/dev/null
    git add -A

    run hk check
    assert_success
}

@test "check_added_large_files - range mode passes a modified pre-existing large file" {
    # A new branch that only modifies a large file the base tree already
    # carries must not be vetoed: the push introduces nothing at that path.
    yes "some text line" | head -c 513000 > big.txt
    git add -A
    git commit -qm "add big.txt"
    git checkout -qb feature
    printf 'more\n' >> big.txt
    git add -A
    git commit -qm "modify big.txt"

    run hk util check-added-large-files --from-ref main --to-ref HEAD big.txt
    assert_success
    refute_output --partial "big.txt"
}

@test "check_added_large_files - range mode fails a large file the range adds" {
    yes "some text line" | head -c 513000 > big.txt
    git add -A
    git commit -qm "add big.txt"
    git checkout -qb feature
    yes "other text line" | head -c 513000 > big-new.txt
    git add -A
    git commit -qm "add big-new.txt"

    run hk util check-added-large-files --from-ref main --to-ref HEAD big.txt big-new.txt
    assert_failure
    assert_output --partial "big-new.txt"
    refute_output --partial "big.txt"
}

@test "check_added_large_files - range mode passes when the range adds no large file" {
    yes "some text line" | head -c 513000 > big.txt
    git add -A
    git commit -qm "add big.txt"
    git checkout -qb feature
    echo "small" > small.txt
    git add -A
    git commit -qm "add small.txt"

    run hk util check-added-large-files --from-ref main --to-ref HEAD big.txt small.txt
    assert_success
}

@test "check_added_large_files - unresolvable from-ref checks every given file" {
    # A base ref that cannot be resolved is a fallback, not a silent pass:
    # every given file is checked, the range-less behavior.
    yes "some text line" | head -c 513000 > big.txt

    run hk util check-added-large-files --from-ref no-such-ref --to-ref HEAD big.txt
    assert_failure
    assert_output --partial "big.txt"
}
