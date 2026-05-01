#!/bin/bash
# Create test folder structure with 10 subfolders of random depth (1-10)
# Each level has 1-20 files

TEST_DIR="/nfs/ihfs/home_metis/serguei/aibkpcl/test_data"

# Clean up if exists
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

# Create README file in test_data root
echo "Test data directory - backup source" > "${TEST_DIR}/README"

# Function to create random files in a directory
create_files() {
    local dir="$1"
    local num_files=$((RANDOM % 20 + 1))
    for ((i = 1; i <= num_files; i++)); do
        echo "File $i in $dir" > "$dir/file_$i.txt"
    done
}

# Function to recursively create directories up to max depth
create_subdirs() {
    local base_dir="$1"
    local current_depth="$2"
    local max_depth="$3"

    # Create 1-20 files at this level
    create_files "$base_dir"

    # If we've reached max depth, stop
    if [[ $current_depth -ge $max_depth ]]; then
        return
    fi

    # Create 1-3 subdirectories
    local num_subdirs=$((RANDOM % 3 + 1))
    for ((i = 1; i <= num_subdirs; i++)); do
        local subdir="${base_dir}/subdir_${i}_d${current_depth}"
        mkdir -p "$subdir"
        create_subdirs "$subdir" $((current_depth + 1)) "$max_depth"
    done
}

# Create 10 subfolders with random depths (1-10)
for ((j = 1; j <= 10; j++)); do
    random_depth=$((RANDOM % 10 + 1))
    folder_name="folder_d${random_depth}_$j"
    folder_path="${TEST_DIR}/${folder_name}"
    mkdir -p "$folder_path"

    # Create README checkpoint file
    echo "Checkpoint for $folder_name" > "${folder_path}/README"

    # Create subdirectories with random depth
    create_subdirs "$folder_path" 1 "$random_depth"

    echo "Created $folder_name with max depth $random_depth"
done

echo ""
echo "Test data created in $TEST_DIR"
echo "Structure:"
find "$TEST_DIR" -type d -name "folder_*" | head -20
