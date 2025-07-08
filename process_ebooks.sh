#!/bin/bash
set -eo pipefail

# --- Script Logic ---
# This script reads its settings from a file named 'ebook_process.conf'
# located in the same directory.

# Find the script's own directory to locate the config file
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
CONFIG_FILE="$SCRIPT_DIR/ebook_process.conf"

# Load the configuration file
if [ ! -f "$CONFIG_FILE" ]; then
    echo "FATAL ERROR: Configuration file not found at '$CONFIG_FILE'."
    echo "Please create it based on the template provided."
    exit 1
else
    # The 'source' command executes the config file, loading its variables
    source "$CONFIG_FILE"
fi

# --- Validate Configuration ---
# Check that critical variables from the config file are set.
if [ -z "$INCOMING_DIR" ] || [ -z "$PROCESSED_DIR" ] || [ -z "$CALIBREDB" ] || [ -z "$EBOOK_CONVERT" ] || [ -z "$EBOOK_META" ]; then
    echo "FATAL ERROR: One or more critical path variables are not set in '$CONFIG_FILE'."
    echo "Please ensure all required settings are filled out."
    exit 1
fi

# Check that the core commands exist.
if [ ! -f "$CALIBREDB" ] || [ ! -f "$EBOOK_CONVERT" ] || [ ! -f "$EBOOK_META" ]; then
    echo "FATAL ERROR: One or more Calibre executables were not found at the specified paths."
    echo "Please correct the paths in '$CONFIG_FILE' after running 'which <command>'."
    exit 1
fi
if ! command -v jq &> /dev/null; then
    echo "FATAL ERROR: The 'jq' command is not found. Please install with: sudo apt install jq -y"
    exit 1
fi


# --- Main Processing Loop ---

mkdir -p "$PROCESSED_DIR"

echo "Starting ebook processing run at $(date)"
echo "Scanning for new books in: $INCOMING_DIR"

find "$INCOMING_DIR" -type f \( -iname "*.epub" -o -iname "*.mobi" -o -iname "*.azw3" \) -print0 | while IFS= read -r -d '' source_file; do
    
    echo "-----------------------------------------------------"
    echo "Processing: $source_file"

    dir_path=$(dirname "$source_file")
    full_filename=$(basename "$source_file")
    base_name_no_ext="${full_filename%.*}"
    processing_successful=true

    # STEP 1: Ensure all three formats exist locally.
    echo "  - Verifying/Creating all target formats (EPUB, MOBI, AZW3)..."
    all_format_paths=()
    target_formats=("epub" "mobi" "azw3")

    for fmt in "${target_formats[@]}"; do
        target_file="$dir_path/$base_name_no_ext.$fmt"
        if [ -f "$target_file" ]; then
            echo "    - Format .$fmt already exists."
        else
            echo "    - Converting to .$fmt..."
            if "$EBOOK_CONVERT" "$source_file" "$target_file"; then
                echo "    - Conversion to .$fmt successful."
                if [ -n "$FILE_OWNER" ]; then
                    chown "$FILE_OWNER" "$target_file"
                fi
            else
                echo "    - ERROR: Conversion to .$fmt failed for '$source_file'."
                processing_successful=false
                [ -f "$target_file" ] && rm "$target_file"
                break
            fi
        fi
        all_format_paths+=("$target_file")
    done

    if ! $processing_successful; then
        echo "  - Aborting processing for this book due to conversion failure."
        continue
    fi

    # STEP 2: Find or Create the book entry in Calibre to get its ID.
    echo "  - Extracting metadata to search Calibre..."
    metadata=$("$EBOOK_META" "$source_file")
    title=$(echo "$metadata" | grep -i '^Title\s*:' | sed 's/^Title\s*:\s*//')
    author=$(echo "$metadata" | grep -i '^Author(s)\s*:' | sed 's/^Author(s)\s*:\s*//' | sed 's/&.*//' | sed 's/,.*//')
    
    book_id=""
    if [ -n "$title" ] && [ -n "$author" ]; then
        echo "  - Searching for Title: '$title'; Author: '$author'"
        book_id=$("$CALIBREDB" list --with-library "$CALIBRE_LIBRARY" -s "title:\"$title\" and authors:\"$author\"" --fields id --limit 1 --for-machine | jq '.[0].id // empty')
    fi

    if [ -z "$book_id" ]; then
        echo "  - Book not found. Attempting to add it to create an entry..."
        epub_file_path="$dir_path/$base_name_no_ext.epub"
        
        add_output=$("$CALIBREDB" add --with-library "$CALIBRE_LIBRARY" --one-book-per-directory "$epub_file_path" 2>&1)
        add_status=$?
        
        if [ $add_status -eq 0 ] && ! echo "$add_output" | grep -q "already exist"; then
            echo "  - Initial add successful. Re-searching to get the new ID..."
            book_id=$("$CALIBREDB" list --with-library "$CALIBRE_LIBRARY" -s "title:\"$title\" and authors:\"$author\"" --fields id --limit 1 --for-machine | jq '.[0].id // empty')
        else
            echo "  - INFO: The book was not added. It is likely a duplicate. Searching for it..."
            book_id=$("$CALIBREDB" list --with-library "$CALIBRE_LIBRARY" -s "title:\"$title\" and authors:\"$author\"" --fields id --limit 1 --for-machine | jq '.[0].id // empty')
        fi
    else
        echo "  - Book found with existing ID: $book_id"
    fi

    # STEP 3: With a valid ID, add all formats to that specific book entry.
    if $processing_successful && [ -n "$book_id" ]; then
        echo "  - Syncing all available formats to book ID $book_id..."
        for format_path in "${all_format_paths[@]}"; do
            format_ext=$(basename "$format_path")
            if ! "$CALIBREDB" add_format --with-library "$CALIBRE_LIBRARY" "$book_id" "$format_path"; then
                echo "    - ERROR: Failed to add format '$format_ext'."
                processing_successful=false
            else
                echo "    - Successfully synced format: $format_ext"
            fi
        done
    elif [ -z "$book_id" ]; then
        echo "  - ERROR: Could not obtain a book ID. Skipping format addition."
        processing_successful=false
    fi

    # STEP 4: Clean up if everything was successful.
    if $processing_successful; then
        echo "  - Processing complete. Moving source files to '$PROCESSED_DIR'..."
        mv "$dir_path/$base_name_no_ext".* "$PROCESSED_DIR/"
    else
        echo "  - Processing failed. Files will remain in '$INCOMING_DIR' for next run."
    fi
done

echo "-----------------------------------------------------"
echo "Ebook processing run finished at $(date)"
