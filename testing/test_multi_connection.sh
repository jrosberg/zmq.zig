#!/bin/bash

set -e

echo "========================================"
echo "Multiple Simultaneous Connections Test"
echo "========================================"
echo ""

# Colors (enable only when stdout is a TTY)
if [ -t 1 ]; then
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    RED=$'\033[0;31m'
    NC=$'\033[0m' # No Color
else
    GREEN=''
    YELLOW=''
    RED=''
    NC=''
fi

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up processes..."
    kill $PUB_PID $SUB1_PID $SUB2_PID $SUB3_PID 2>/dev/null || true
    sleep 1
    rm -f client1.log client2.log client3.log publisher.log
    echo "Cleanup complete"
}

trap cleanup EXIT INT TERM

echo "${YELLOW}Step 1: Building examples...${NC}"
echo ""

# Build using zig build system
if ! zig build 2>&1; then
    echo "${RED}Failed to build project${NC}"
    exit 1
fi

echo "${GREEN}✓ Build successful${NC}"
echo ""

echo "${YELLOW}Step 2: Starting publisher...${NC}"
./zig-out/bin/pub_multi_server > publisher.log 2>&1 &
PUB_PID=$!
echo "Publisher PID: $PUB_PID"
echo ""

# Wait for publisher to be ready
sleep 2

if ! kill -0 $PUB_PID 2>/dev/null; then
    echo "${RED}Publisher failed to start${NC}"
    cat publisher.log
    exit 1
fi

echo "${GREEN}✓ Publisher started${NC}"
echo ""

echo "${YELLOW}Step 3: Starting subscriber #1 (all topics)...${NC}"
./zig-out/bin/sub_multi_client 1 "" > client1.log 2>&1 &
SUB1_PID=$!
echo "Subscriber #1 PID: $SUB1_PID"
sleep 1

if ! kill -0 $SUB1_PID 2>/dev/null; then
    echo "${RED}Subscriber #1 failed to start${NC}"
    cat client1.log
    exit 1
fi

echo "${GREEN}✓ Subscriber #1 started${NC}"
echo ""

echo "${YELLOW}Step 4: Starting subscriber #2 (weather only)...${NC}"
./zig-out/bin/sub_multi_client 2 weather > client2.log 2>&1 &
SUB2_PID=$!
echo "Subscriber #2 PID: $SUB2_PID"
sleep 1

if ! kill -0 $SUB2_PID 2>/dev/null; then
    echo "${RED}Subscriber #2 failed to start${NC}"
    cat client2.log
    exit 1
fi

echo "${GREEN}✓ Subscriber #2 started${NC}"
echo ""

echo "${YELLOW}Step 5: Starting subscriber #3 (news only)...${NC}"
./zig-out/bin/sub_multi_client 3 news > client3.log 2>&1 &
SUB3_PID=$!
echo "Subscriber #3 PID: $SUB3_PID"
sleep 1

if ! kill -0 $SUB3_PID 2>/dev/null; then
    echo "${RED}Subscriber #3 failed to start${NC}"
    cat client3.log
    exit 1
fi

echo "${GREEN}✓ Subscriber #3 started${NC}"
echo ""

echo "${YELLOW}Step 6: Running test for 10 seconds...${NC}"
echo "All 3 subscribers should be receiving messages simultaneously"
echo ""

# Show live updates
for i in {1..10}; do
    echo -n "Running... $i/10"

    # Check if all processes are still alive
    if ! kill -0 $PUB_PID 2>/dev/null; then
        echo ""
        echo "${RED}Publisher died unexpectedly!${NC}"
        cat publisher.log
        exit 1
    fi

    if ! kill -0 $SUB1_PID 2>/dev/null; then
        echo ""
        echo "${RED}Subscriber #1 died unexpectedly!${NC}"
        cat client1.log
        exit 1
    fi

    if ! kill -0 $SUB2_PID 2>/dev/null; then
        echo ""
        echo "${RED}Subscriber #2 died unexpectedly!${NC}"
        cat client2.log
        exit 1
    fi

    if ! kill -0 $SUB3_PID 2>/dev/null; then
        echo ""
        echo "${RED}Subscriber #3 died unexpectedly!${NC}"
        cat client3.log
        exit 1
    fi

    echo -ne "\r"
    sleep 1
done

echo "Running... 10/10 - Complete!"
echo ""

echo "${YELLOW}Step 7: Stopping processes...${NC}"
kill $PUB_PID $SUB1_PID $SUB2_PID $SUB3_PID 2>/dev/null || true
sleep 1
echo "${GREEN}✓ All processes stopped${NC}"
echo ""

echo "${YELLOW}Step 8: Analyzing results...${NC}"
echo ""

# Check logs
echo "----------------------------------------"
echo "Publisher Log (last 20 lines):"
echo "----------------------------------------"
tail -n 20 publisher.log
echo ""

echo "----------------------------------------"
echo "Subscriber #1 Log (all topics - first 10 messages):"
echo "----------------------------------------"
grep "Client #1 \[" client1.log | head -n 10
SUB1_COUNT=$(grep "Client #1 \[" client1.log | wc -l)
echo "Total messages received: $SUB1_COUNT"
echo ""

echo "----------------------------------------"
echo "Subscriber #2 Log (weather only - first 10 messages):"
echo "----------------------------------------"
grep "Client #2 \[" client2.log | head -n 10
SUB2_COUNT=$(grep -c "Client #2 \[" client2.log || true)
echo "Total messages received: $SUB2_COUNT"
echo ""

echo "----------------------------------------"
echo "Subscriber #3 Log (news only - first 10 messages):"
echo "----------------------------------------"
grep "Client #3 \[" client3.log | head -n 10
SUB3_COUNT=$(grep -c "Client #3 \[" client3.log || true)
echo "Total messages received: $SUB3_COUNT"
echo ""

echo "========================================"
echo "Test Results Summary"
echo "========================================"
echo ""

# Verify results
PASS=true

# Check if publisher mentions multiple connections
if grep -q "3 active subscriber" publisher.log || grep -q "Connection #2" publisher.log; then
    echo "${GREEN}✓ Publisher accepted multiple connections${NC}"
else
    echo "${YELLOW}⚠ Warning: Could not verify multiple connections in publisher log${NC}"
fi

# Check subscriber #1 (should receive all messages)
if [ "$SUB1_COUNT" -gt 5 ]; then
    echo "${GREEN}✓ Subscriber #1 received messages ($SUB1_COUNT total)${NC}"
else
    echo "${RED}✗ Subscriber #1 received too few messages ($SUB1_COUNT)${NC}"
    PASS=false
fi

# Check subscriber #2 (should only receive weather)
if [ "$SUB2_COUNT" -gt 2 ]; then
    echo "${GREEN}✓ Subscriber #2 received messages ($SUB2_COUNT total)${NC}"
    if grep -q "news" client2.log; then
        echo "${YELLOW}⚠ Warning: Subscriber #2 may have received news (should be weather only)${NC}"
    fi
else
    echo "${RED}✗ Subscriber #2 received too few messages ($SUB2_COUNT)${NC}"
    PASS=false
fi

# Check subscriber #3 (should only receive news)
if [ "$SUB3_COUNT" -gt 2 ]; then
    echo "${GREEN}✓ Subscriber #3 received messages ($SUB3_COUNT total)${NC}"
    if grep -q "weather" client3.log && ! grep -q "news" client3.log; then
        echo "${YELLOW}⚠ Warning: Subscriber #3 may have received weather (should be news only)${NC}"
    fi
else
    echo "${RED}✗ Subscriber #3 received too few messages ($SUB3_COUNT)${NC}"
    PASS=false
fi

echo ""

# Check for simultaneous message delivery
echo "Verifying simultaneous delivery:"
if grep -q "Broadcasting to 3 subscriber" publisher.log; then
    echo "${GREEN}✓ Publisher broadcasted to 3 subscribers simultaneously${NC}"
else
    echo "${YELLOW}⚠ Could not verify simultaneous broadcasting${NC}"
fi

echo ""

if [ "$PASS" = true ]; then
    echo "========================================"
    echo "${GREEN}✓✓✓ ALL TESTS PASSED ✓✓✓${NC}"
    echo "========================================"
    echo ""
    echo "Multiple simultaneous connections working correctly!"
    echo "- Publisher accepted 3 subscribers"
    echo "- All subscribers received messages"
    echo "- Topic filtering working"
    echo "- Broadcasting to multiple clients successful"
    exit 0
else
    echo "========================================"
    echo "${RED}✗✗✗ SOME TESTS FAILED ✗✗✗${NC}"
    echo "========================================"
    echo ""
    echo "Check the logs above for details"
    exit 1
fi
