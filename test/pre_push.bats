#!/usr/bin/env bats

setup() {
    load 'test_helper/common_setup'
    _common_setup
    TEST_REPO_DIR="$(temp_make)"
    pushd "$TEST_REPO_DIR" || exit
    git init --bare
    popd || exit
    git remote add origin "$TEST_REPO_DIR"
}
teardown() {
    _common_teardown
    chmod -R u+w "$TEST_REPO_DIR"
    temp_del "$TEST_REPO_DIR"
}

require_git_2_54() {
    local version major minor
    version="$(git version | awk '{print $3}')"
    major="${version%%.*}"
    minor="${version#*.}"
    minor="${minor%%.*}"
    if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 54 ]; }; then
        skip "git 2.54+ required for config-based hooks"
    fi
}

@test "pre-push hook" {
    export NO_COLOR=1
    if [ "$HK_LIBGIT2" = "0" ]; then
        skip "libgit2 is not installed"
    fi
    cat <<EOF > hk.pkl
amends "$PKL_PATH/Config.pkl"
import "$PKL_PATH/Builtins.pkl"
hooks { ["pre-push"] { steps { ["prettier"] = Builtins.prettier } } }
EOF
    git add hk.pkl
    git commit -m "install hk"
    git push origin main
    # Use legacy shim mode: config-based pre-push hooks have different env/cwd
    # semantics that would need separate test coverage.
    hk install --legacy
    echo 'console.log("test")' > test.js
    git add test.js
    git commit -m "test"
    HK_LOG=trace run git push origin main
    assert_failure
    assert_output --partial "[warn] test.js"
}

@test "pre-push hook allows pushing annotated tags" {
    cat <<EOF > hk.pkl
amends "$PKL_PATH/Config.pkl"
hooks {
    ["pre-push"] {
        steps {
            ["print-files"] { check = "echo '{{files}}'" }
        }
    }
}
EOF
    git add hk.pkl
    git commit -m "test(pre-push): install hk"
    git push origin main
    git remote set-head origin --auto

    echo "tagged content" > tagged.txt
    git add tagged.txt
    git commit -m "test(pre-push): add tagged content"
    git tag -a v1.0.0 -m v1.0.0
    hk install --legacy

    run git push origin v1.0.0

    assert_success
    assert_output --partial "print-files – tagged.txt"
    run git ls-remote --exit-code origin refs/tags/v1.0.0
    assert_success
}

@test "config-based pre-push hook checks pushed files" {
    require_git_2_54
    export NO_COLOR=1
    if [ "$HK_LIBGIT2" = "0" ]; then
        skip "libgit2 is not installed"
    fi
    cat <<EOF > hk.pkl
amends "$PKL_PATH/Config.pkl"
import "$PKL_PATH/Builtins.pkl"
hooks { ["pre-push"] { steps { ["prettier"] = Builtins.prettier } } }
EOF
    git add hk.pkl
    git commit -m "install hk"
    git push origin main
    hk install
    echo 'console.log("test")' > test.js
    git add test.js
    git commit -m "test"

    run git push origin main

    assert_failure
    assert_output --partial "[warn] test.js"
}

@test "pre-push hook on new branch first push" {
    export NO_COLOR=1
    if [ "$HK_LIBGIT2" = "0" ]; then
        skip "libgit2 is not installed"
    fi
    cat <<EOF > hk.pkl
amends "$PKL_PATH/Config.pkl"
import "$PKL_PATH/Builtins.pkl"
hooks { ["pre-push"] { steps { ["prettier"] = Builtins.prettier } } }
EOF
    git add hk.pkl
    git commit -m "install hk"
    git push origin main
    hk install --legacy

    # Create a new branch with a file that needs linting and push it for the
    # first time. The pre-push hook receives a remote sha of all-zeros for a
    # new branch — the inverted filter regression caused this push to either
    # error out resolving refs/remotes/origin/HEAD or skip linting entirely.
    git checkout -b feature/new-thing
    echo 'console.log("new")' > new.js
    git add new.js
    git commit -m "add new.js"
    HK_LOG=trace run git push -u origin feature/new-thing
    assert_failure
    assert_output --partial "[warn] new.js"
}

@test "pre-push hook on first push to empty remote" {
    export NO_COLOR=1
    if [ "$HK_LIBGIT2" = "0" ]; then
        skip "libgit2 is not installed"
    fi
    cat <<EOF > hk.pkl
amends "$PKL_PATH/Config.pkl"
import "$PKL_PATH/Builtins.pkl"
hooks { ["pre-push"] { steps { ["prettier"] = Builtins.prettier } } }
EOF
    git add hk.pkl
    git commit -m "install hk"
    hk install --legacy

    # First push to an empty remote: no origin/HEAD, no remote branches, so
    # default_branch() falls through to the literal "origin/HEAD". The push
    # should lint the pushed files, not fail resolving that ref.
    echo 'console.log("first")' > first.js
    git add first.js
    git commit -m "add first.js"
    HK_LOG=trace run git push -u origin main
    assert_failure
    assert_output --partial "[warn] first.js"
}

@test "pre-push hook skips branch deletion" {
    export NO_COLOR=1
    if [ "$HK_LIBGIT2" = "0" ]; then
        skip "libgit2 is not installed"
    fi
    cat <<EOF > hk.pkl
amends "$PKL_PATH/Config.pkl"
import "$PKL_PATH/Builtins.pkl"
hooks { ["pre-push"] { steps { ["prettier"] = Builtins.prettier } } }
EOF
    git add hk.pkl
    git commit -m "install hk"
    git push origin main

    # Push a branch we'll later delete — install the hook only after this
    # setup push so the initial push isn't gated on linting.
    git checkout -b feature/to-delete
    echo 'console.log("x")' > x.js
    git add x.js
    git commit -m "add x.js"
    git push -u origin feature/to-delete
    git checkout main

    hk install --legacy

    # Add a file on main that WOULD fail linting if linted. This guards
    # against a regression where deletions slip past the EMPTY_REF guard
    # and end up running files_between_refs(default_branch, HEAD) — that
    # diff would include this file and trigger a lint failure.
    echo 'console.log("unformatted")' > unrelated.js
    git add unrelated.js
    git -c core.hooksPath=/dev/null commit -m "unrelated change on main"

    # Deleting a remote branch should not lint anything — the EMPTY_REF
    # guard in hook.rs short-circuits when to_ref is the all-zeros sha.
    run git push origin --delete feature/to-delete
    assert_success
    refute_output --partial "[warn] unrelated.js"
}

@test "pre-push warns on malformed stdin lines instead of crashing" {
    cat <<EOF > hk.pkl
amends "$PKL_PATH/Config.pkl"
hooks {
    ["pre-push"] {
        steps {
            ["print-files"] { check = "echo '{{files}}'" }
        }
    }
}
EOF
    git add hk.pkl
    git commit -m "test(pre-push): install hk"
    git push origin main
    git remote set-head origin --auto

    # A line with fewer than four fields used to panic in PrePushRefs::from,
    # which indexes parts[3] without bounds checking.
    run bash -c "printf 'refs/heads/main\n' | hk run pre-push origin example"

    assert_success
    assert_output --partial "Ignoring malformed stdin line \""
    refute_output --partial "panicked"
}

@test "pre-push warns on abbreviated commit hashes from stdin" {
    cat <<EOF > hk.pkl
amends "$PKL_PATH/Config.pkl"
hooks {
    ["pre-push"] {
        steps {
            ["print-files"] { check = "echo '{{files}}'" }
        }
    }
}
EOF
    git add hk.pkl
    git commit -m "test(pre-push): install hk"
    git push origin main
    git remote set-head origin --auto

    run bash -c "printf 'refs/heads/main abc refs/heads/main def\n' | hk run pre-push origin example"

    assert_success
    assert_output --partial "second and fourth parts must be 40 or 64 lowercase hexits"
    refute_output --partial "panicked"
}

_write_large_files_config() {
    cat <<EOF > hk.pkl
amends "$PKL_PATH/Config.pkl"

hooks {
    ["pre-push"] {
        steps {
            ["check-added-large-files"] {
                check = "hk util check-added-large-files --from-ref {{from_ref}} --to-ref {{to_ref}} {{files}}"
                glob = "**/*"
            }
        }
    }
}
EOF
}

@test "pre-push new-branch push passes a modified pre-existing large file" {
    # A first push of a new branch whose range only modifies a large file the
    # remote already carries: hk picks the base the remote shares history with
    # and the guard judges only files the push adds, so this must not veto.
    export NO_COLOR=1
    if [ "$HK_LIBGIT2" = "0" ]; then
        skip "libgit2 is not installed"
    fi
    _write_large_files_config
    yes "some text line" | head -c 513000 > big.txt
    git add hk.pkl big.txt
    git commit -qm "add big.txt"
    git push -q origin main
    hk install --legacy

    git checkout -qb feature/big-modification
    printf 'more\n' >> big.txt
    git add big.txt
    git commit -qm "modify big.txt"

    HK_LOG=trace run git push -u origin feature/big-modification
    assert_success
    refute_output --partial "big.txt"
}

@test "pre-push new-branch push still blocks a large file it adds" {
    # The scoping must not weaken the guard: a large file the pushed range
    # adds is new on the remote and still vetoes the push.
    export NO_COLOR=1
    if [ "$HK_LIBGIT2" = "0" ]; then
        skip "libgit2 is not installed"
    fi
    _write_large_files_config
    echo "small" > small.txt
    git add hk.pkl small.txt
    git commit -qm "add small.txt"
    git push -q origin main
    hk install --legacy

    git checkout -qb feature/big-addition
    yes "other text line" | head -c 513000 > big-new.txt
    git add big-new.txt
    git commit -qm "add big-new.txt"

    HK_LOG=trace run git push -u origin feature/big-addition
    assert_failure
    assert_output --partial "big-new.txt"
}

@test "pre-push new-branch push scopes a file step to the pushed range" {
    # hk fills {{from_ref}}/{{to_ref}} from the refs git hands pre-push. On a
    # new-branch first push the base is the remote ref the remote already has
    # (the remote sha is all-zeros), so the step sees the pushed range, not
    # the whole default-branch diff.
    export NO_COLOR=1
    if [ "$HK_LIBGIT2" = "0" ]; then
        skip "libgit2 is not installed"
    fi
    cat <<EOF > hk.pkl
amends "$PKL_PATH/Config.pkl"
hooks {
    ["pre-push"] {
        steps {
            ["print-files"] { check = "echo \"{{from_ref}} {{to_ref}} {{files}}\"" }
        }
    }
}
EOF
    echo "content" > ranged.txt
    git add hk.pkl ranged.txt
    git commit -qm "install hk"
    git push -q origin main
    hk install --legacy

    git checkout -qb feature/range-print
    printf 'more\n' >> ranged.txt
    git add ranged.txt
    git commit -qm "modify ranged.txt"

    run git push -u origin feature/range-print
    assert_success
    assert_output --partial "refs/remotes/origin/main"
    assert_output --partial "ranged.txt"
}
