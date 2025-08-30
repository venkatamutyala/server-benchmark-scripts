#!/bin/bash
#
# Hard Drive / SSD Endurance Benchmark Script using 'fio'
#
# VERSION 6: ROBUST DRIVE DETECTION & MENU
#
# This version improves drive detection to include LVM volumes (e.g., /dev/mapper)
# and replaces the 'select' menu with a more reliable 'read' prompt to prevent
# issues in certain terminal environments.
#
# PREREQUISITES:
# You must have 'fio' installed.
#   - On Debian/Ubuntu: sudo apt-get update && sudo apt-get install -y fio
#   - On CentOS/RHEL:   sudo yum install -y fio
#   - On macOS:         brew install fio
#
# --- VERY IMPORTANT WARNING ---
# This script can be DESTRUCTIVE if you point it at a raw block device
# (e.g., /dev/sda). By default, it runs in a NON-DESTRUCTIVE mode by creating
# a test file in a specified directory.
#
# DO NOT CHANGE TARGET_DEVICE to a raw disk unless you are absolutely sure
# you want to WIPE ALL DATA from it.
#

set -e
trap 'echo "An error occurred. Exiting."; exit 1' ERR

# --- Configuration ---
# The duration in seconds for each test.
# 8 hours = 8 * 60 * 60 = 28800 seconds.
# For a quicker, but still meaningful test, you could use 3600 (1 hour).
# For a quick snapshot, use 60 (1 minute).
RUNTIME="28800"


# --- Script Start ---

# Check if fio is installed
if ! command -v fio &> /dev/null
then
    echo "'fio' could not be found. Please install it first."
    exit 1
fi

# --- Drive Selection Menu ---
echo "Detecting available drives..."

# Use df to find block devices and format them for the menu.
# Added 'mapper' to the regex to include LVM volumes.
mapfile -t mount_info < <(df -hTP | awk 'NR>1 && ($1 ~ /^\/dev\/(sd|nvme|vd|hd|mapper)/) {printf "%s (%s, %s, %s free)\n", $7, $1, $2, $4}')

if [ ${#mount_info[@]} -eq 0 ]; then
    echo "Error: No suitable drives found to test (e.g., /dev/sda, /dev/nvme0n1)."
    echo "Please ensure your drives are mounted."
    exit 1
fi

echo "Please select the drive you want to benchmark:"
# Manually print options with numbers
for i in "${!mount_info[@]}"; do
    printf "  %d) %s\n" "$((i+1))" "${mount_info[$i]}"
done
# Add a quit option
quit_option=$((${#mount_info[@]}+1))
printf "  %d) Quit\n" "$quit_option"

# Read user input using a more robust 'read' command
read -p "Enter your choice [1-$quit_option]: " choice

# Validate the choice
if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#mount_info[@]}" ]; then
    # A valid drive was selected
    opt="${mount_info[$((choice-1))]}"
    TARGET_DIR=$(echo "$opt" | awk '{print $1}')
    echo "You have selected the drive mounted at: $TARGET_DIR"
elif [[ "$choice" == "$quit_option" ]]; then
    # Quit was selected
    echo "Exiting."
    exit 0
else
    # Invalid choice
    echo "Invalid option. Exiting."
    exit 1
fi


# The name of the test file, now based on the selected TARGET_DIR.
TEST_FILE="$TARGET_DIR/fio-benchmark-testfile"


# Check if target directory is writable
if ! touch "$TEST_FILE.tmp" 2>/dev/null; then
    echo "Error: Directory '$TARGET_DIR' is not writable. Please check permissions or run with sudo."
    exit 1
fi
rm -f "$TEST_FILE.tmp"


# --- Dynamic File Size Calculation ---
echo "Calculating available space in '$TARGET_DIR'..."
# Get available space in kilobytes using 'df'. Using -P for POSIX standard output.
AVAILABLE_KB=$(df -Pk "$TARGET_DIR" | tail -n 1 | awk '{print $4}')

# We will use 95% of available space to be safe and avoid "disk full" errors during the test.
# 'awk' is used for the floating-point multiplication, then printf formats it as an integer.
FILE_SIZE_KB=$(awk "BEGIN {printf \"%.0f\", $AVAILABLE_KB * 0.95}")

if (( FILE_SIZE_KB < 10240 )); then # Check if there's at least 10MB of space
    echo "Error: Not enough free space in '$TARGET_DIR' to run a meaningful test."
    exit 1
fi

# Create the final size string for fio (e.g., "123456k")
FILE_SIZE="${FILE_SIZE_KB}k"
# Also calculate GB for a human-friendly display
FILE_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $FILE_SIZE_KB / 1024 / 1024}")


# --- Define the fio command options ---
# These options are shared across all the tests below.
#
# --name=benchmark:       A simple name for the test job.
# --ioengine=libaio:      The I/O engine to use. 'libaio' is the standard asynchronous
#                         engine on Linux and is highly efficient.
# --direct=1:             CRITICAL! This tells fio to bypass the host OS page cache.
#                         This ensures we are testing the performance of the drive itself
#                         and not the system's RAM.
# --size=${FILE_SIZE}:    The total size of the test file to be created.
# --runtime=${RUNTIME}:   The duration for which each test will run, in seconds.
# --group_reporting:      Reports aggregate statistics for the entire job group.
# --output-format=normal: The default, human-readable output format.
FIO_OPTS="--name=benchmark --ioengine=libaio --direct=1 --size=${FILE_SIZE} --runtime=${RUNTIME} --group_reporting --output-format=normal"

# --- Test Functions ---

run_seq_write() {
    echo ""
    echo "--- Test: Sequential Write (Duration: ${RUNTIME}s) ---"
    # --filename="$TEST_FILE": The file fio will read from and write to.
    # --rw=write:              Specifies a sequential write pattern.
    # --bs=1M:                 Sets the block size to 1 Megabyte, good for simulating large file transfers.
    fio $FIO_OPTS --filename="$TEST_FILE" --rw=write --bs=1M
    echo "--- Sequential Write Test Complete ---"
}

run_seq_read() {
    echo ""
    echo "--- Test: Sequential Read (Duration: ${RUNTIME}s) ---"
    # --rw=read:   Specifies a sequential read pattern.
    # --bs=1M:     Again, a 1MB block size for large file simulation.
    fio $FIO_OPTS --filename="$TEST_FILE" --rw=read --bs=1M
    echo "--- Sequential Read Test Complete ---"
}

run_rand_write() {
    echo ""
    echo "--- Test: Random Write IOPS (Duration: ${RUNTIME}s) ---"
    # --rw=randwrite: Specifies a random write pattern. This is much more stressful for an SSD
    #                 than sequential writes and is a better indicator of real-world application performance.
    # --bs=4k:        Sets the block size to 4 Kilobytes, which is a very common I/O size for
    #                 databases, operating systems, and applications.
    fio $FIO_OPTS --filename="$TEST_FILE" --rw=randwrite --bs=4k
    echo "--- Random Write Test Complete ---"
}

run_rand_read() {
    echo ""
    echo "--- Test: Random Read IOPS (Duration: ${RUNTIME}s) ---"
    # --rw=randread: Specifies a random read pattern. Excellent for testing database lookup speeds
    #                and application launch times.
    # --bs=4k:       Using the common 4K block size.
    fio $FIO_OPTS --filename="$TEST_FILE" --rw=randread --bs=4k
    echo "--- Random Read Test Complete ---"
}

run_mixed_rw() {
    echo ""
    echo "--- Test: Mixed Random Read/Write (Duration: ${RUNTIME}s) ---"
    # --rw=randrw:   Specifies a mixed pattern of random reads and writes happening at the same time.
    # --rwmixread=70: Defines the mix: 70% of the operations will be reads, and 30% will be writes.
    #                 This is a very realistic workload for a busy server.
    # --bs=4k:         Using the common 4K block size.
    fio $FIO_OPTS --filename="$TEST_FILE" --rw=randrw --bs=4k --rwmixread=70
    echo "--- Mixed Random Read/Write Test Complete ---"
}

run_all_tests() {
    run_seq_write
    run_seq_read
    run_rand_write
    run_rand_read
    run_mixed_rw
}


# --- Main Menu ---

echo ""
echo "--- Hard Drive ENDURANCE Benchmark ---"
echo "Target Drive:     $TARGET_DIR"
echo "Test File Size:   ~${FILE_SIZE_GB} GB (95% of available free space)"
echo "Duration per Test: ${RUNTIME}s ($(awk "BEGIN {printf \"%.2f\", $RUNTIME / 3600}") hours)"
echo ""

echo "Please select a benchmark to run:"
echo "  1) Sequential Write"
echo "  2) Sequential Read"
echo "  3) Random Write (4k blocks)"
echo "  4) Random Read (4k blocks)"
echo "  5) Mixed Random Read/Write (70/30)"
echo "  6) ALL TESTS (will run sequentially)"
echo ""
read -p "Enter your choice [1-6]: " choice
echo ""

# --- Execution Logic ---

# Clean up any previous test file before starting
rm -f "$TEST_FILE"

case $choice in
    1)
        read -p "This will run the Sequential Write test for $(awk "BEGIN {printf \"%.2f\", $RUNTIME / 3600}") hours. Press [Enter] to continue..."
        run_seq_write
        ;;
    2)
        read -p "This will run the Sequential Read test for $(awk "BEGIN {printf \"%.2f\", $RUNTIME / 3600}") hours. Press [Enter] to continue..."
        # The read test requires the file to exist, so we create it first with a quick write.
        echo "Pre-creating test file..."
        fio --name=precreate --ioengine=libaio --direct=1 --size=${FILE_SIZE} --filename="$TEST_FILE" --rw=write --bs=1M > /dev/null 2>&1
        run_seq_read
        ;;
    3)
        read -p "This will run the Random Write test for $(awk "BEGIN {printf \"%.2f\", $RUNTIME / 3600}") hours. Press [Enter] to continue..."
        run_rand_write
        ;;
    4)
        read -p "This will run the Random Read test for $(awk "BEGIN {printf \"%.2f\", $RUNTIME / 3600}") hours. Press [Enter] to continue..."
        # The read test requires the file to exist, so we create it first with a quick write.
        echo "Pre-creating test file..."
        fio --name=precreate --ioengine=libaio --direct=1 --size=${FILE_SIZE} --filename="$TEST_FILE" --rw=write --bs=1M > /dev/null 2>&1
        run_rand_read
        ;;
    5)
        read -p "This will run the Mixed R/W test for $(awk "BEGIN {printf \"%.2f\", $RUNTIME / 3600}") hours. Press [Enter] to continue..."
        run_mixed_rw
        ;;
    6)
        TOTAL_HOURS=$(awk "BEGIN {printf \"%.2f\", ($RUNTIME * 5) / 3600}")
        read -p "WARNING: This will run ALL 5 tests for a total of ~${TOTAL_HOURS} hours. Press [Enter] to continue..."
        run_all_tests
        ;;
    *)
        echo "Invalid option. Exiting."
        exit 1
        ;;
esac


# Clean up the test file
echo "Cleaning up the test file..."
rm -f "$TEST_FILE"

echo ""
echo "--- Benchmark Finished ---"

