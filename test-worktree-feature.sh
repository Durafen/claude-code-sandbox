#!/bin/bash

# Integration tests for claude-code-sandbox --worktree-branch feature

# Setup Phase
TEST_DIR="/tmp/worktree-test"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

echo "Setting up test environment in $TEST_DIR..."

# Create a fake docker command if real docker is not available
if ! command -v docker >/dev/null 2>&1 || ! docker ps >/dev/null 2>&1; then
    echo "Docker not available, using fake docker for testing worktree logic..."
    mkdir -p "$TEST_DIR/bin"
    cat <<'EOF' > "$TEST_DIR/bin/docker"
#!/bin/bash
# Fake docker that just logs calls
echo "Fake docker called with: $*"
case "$1" in
    run|build|rmi|images)
        if [[ "$*" == *"images -q"* ]]; then
            echo "fake-image-id"
        fi
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "$TEST_DIR/bin/docker"
    export PATH="$TEST_DIR/bin:$PATH"
fi

# Create a "remote" repository
mkdir -p "$TEST_DIR/remote"
cd "$TEST_DIR/remote"
git init --bare -b main >/dev/null

# Create a "local" repository
cd "$TEST_DIR"
git clone remote local >/dev/null 2>&1
cd local
git config user.email "test@example.com"
git config user.name "Test User"

# Initial commit on main
touch README.md
git add README.md
git commit -m "initial commit" >/dev/null
git push origin main >/dev/null 2>&1

# Create branches
git checkout -b feat/test >/dev/null 2>&1
echo "feature-content" > feature.txt
git add feature.txt
git commit -m "add feature" >/dev/null
git push origin feat/test >/dev/null 2>&1

git checkout -b feature/feature-name >/dev/null 2>&1
echo "feature-name-content" > feature-name.txt
git add feature-name.txt
git commit -m "add feature name" >/dev/null
git push origin feature/feature-name >/dev/null 2>&1

git checkout main >/dev/null 2>&1

# Copy script and dependencies to local repo
cp /workspace/claude-code-sandbox .
cp /workspace/Dockerfile .
mkdir -p completions
cp /workspace/completions/claude-code-sandbox completions/

# Make it executable
chmod +x claude-code-sandbox

# Helper for PASS/FAIL
PASS_COUNT=0
FAIL_COUNT=0

test_pass() {
    echo -e "\033[0;32mPASS: $1\033[0m"
    PASS_COUNT=$((PASS_COUNT + 1))
}

test_fail() {
    echo -e "\033[0;31mFAIL: $1\033[0m"
    echo "  $2"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# Run tests
echo "Starting tests..."

# Test 1: Shell mode with worktree from existing branch
echo "Running Test 1..."
./claude-code-sandbox --worktree-branch=feat/test -s -n 'echo' >/tmp/test1.out 2>&1
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ] && [ -d ".worktrees/feat-test" ]; then
    test_pass "Test 1: Shell mode worktree directory created"
else
    test_fail "Test 1: Shell mode failed" "Exit: $EXIT_CODE, Output: $(cat /tmp/test1.out)"
fi

# Test 2: Claude mode with worktree
echo "Running Test 2..."
./claude-code-sandbox --worktree-branch=feat/test -c -n 'echo' >/tmp/test2.out 2>&1
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ] && grep -q ".worktrees/feat-test:/workspace" /tmp/test2.out; then
    test_pass "Test 2: Claude mode worktree mount path verified"
else
    test_fail "Test 2: Claude mode failed" "Exit: $EXIT_CODE, Output: $(cat /tmp/test2.out)"
fi

# Test 3: Non-interactive mode with worktree
echo "Running Test 3..."
./claude-code-sandbox --worktree-branch=feat/test -n 'pwd' >/tmp/test3.out 2>&1
EXIT_CODE=$?
ABS_WT_PATH=$(cd .worktrees/feat-test && pwd)
if [ $EXIT_CODE -eq 0 ] && grep -q "Using worktree: $ABS_WT_PATH" /tmp/test3.out; then
    test_pass "Test 3: Non-interactive mode logs show worktree path"
else
    test_fail "Test 3: Non-interactive mode failed" "Exit: $EXIT_CODE, Expected $ABS_WT_PATH. Output: $(cat /tmp/test3.out)"
fi

# Test 4: Relative path worktree
echo "Running Test 4..."
mkdir -p "$TEST_DIR/test-worktree-rel"
./claude-code-sandbox --worktree-branch=../test-worktree-rel -n 'pwd' >/tmp/test4.out 2>&1
EXIT_CODE=$?
ABS_REL_PATH=$(cd "$TEST_DIR/test-worktree-rel" && pwd)
if [ $EXIT_CODE -eq 0 ] && grep -q "$ABS_REL_PATH:/workspace" /tmp/test4.out; then
    test_pass "Test 4: Relative path worktree verified"
else
    test_fail "Test 4: Relative path failed" "Exit: $EXIT_CODE, Output: $(cat /tmp/test4.out)"
fi

# Test 5: Non-existent branch (fallback to HEAD)
echo "Running Test 5..."
./claude-code-sandbox --worktree-branch=nonexistent-branch -n 'ls' >/tmp/test5.out 2>&1
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ] && grep -q "falling back to HEAD" /tmp/test5.out && [ -d ".worktrees/nonexistent-branch" ]; then
    test_pass "Test 5: Fallback to HEAD worked"
else
    test_fail "Test 5: Fallback to HEAD failed" "Exit: $EXIT_CODE, Output: $(cat /tmp/test5.out)"
fi

# Test 6: Cleanup flag
echo "Running Test 6..."
./claude-code-sandbox --worktree-branch=feat/test --cleanup-worktree -n 'echo cleaning' >/tmp/test6.out 2>&1
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ] && [ ! -d ".worktrees/feat-test" ]; then
    test_pass "Test 6: Cleanup worktree functionality worked"
else
    test_fail "Test 6: Cleanup failed" "Exit: $EXIT_CODE, Worktree still exists. Output: $(cat /tmp/test6.out)"
fi

# Test 7: Path with slashes converted
echo "Running Test 7..."
./claude-code-sandbox --worktree-branch=feature/feature-name -n 'ls' >/tmp/test7.out 2>&1
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ] && [ -d ".worktrees/feature-feature-name" ]; then
    test_pass "Test 7: Slashes converted to dashes"
else
    test_fail "Test 7: Slash conversion failed" "Exit: $EXIT_CODE, Output: $(cat /tmp/test7.out)"
fi

# Test 8: Worktree with --build flag
echo "Running Test 8..."
./claude-code-sandbox --worktree-branch=feat/test --build -n 'echo' >/tmp/test8.out 2>&1
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ] && grep -q "Fake docker called with: build" /tmp/test8.out; then
    test_pass "Test 8: Worktree with --build flag called docker build"
else
    test_fail "Test 8: Worktree with --build flag failed" "Exit: $EXIT_CODE, Output: $(cat /tmp/test8.out)"
fi

# Summary
echo ""
echo "Test Summary:"
echo "PASS: $PASS_COUNT"
echo "FAIL: $FAIL_COUNT"

# Final Cleanup
echo "Cleaning up test directory..."
cd /workspace
if [ -d "$TEST_DIR/local" ]; then
    cd "$TEST_DIR/local"
    git worktree list --porcelain | grep "^worktree" | cut -d' ' -f2 | xargs -I {} git worktree remove -f {} 2>/dev/null || true
fi
rm -rf "$TEST_DIR"
rm -f /tmp/test[1-8].out

if [ $FAIL_COUNT -eq 0 ]; then
    exit 0
else
    exit 1
fi
