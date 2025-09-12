#
# A bash function that reads an integer from a file, increments it by one,
# and writes the new value back to the file.
#
# @param {string} $1 - The path to the file containing the number.
#
increment_file_number() {
    # 1. Check if a filename was provided as an argument.
    if [[ -z "$1" ]]; then
        # Print to standard error (>&2)
        echo "Error: No filename provided." >&2
        return 1 # Exit with an error code
    fi

    local filename="$1"

    # 2. Check if the file actually exists.
    if [[ ! -f "$filename" ]]; then
        echo "Error: File '$filename' not found." >&2
        return 1
    fi

    # 3. Read the number from the file.
    local number
    number=$(cat "$filename")

    # 4. Check if the file's content is a valid integer.
    # This regex allows for an optional leading minus sign.
    if ! [[ "$number" =~ ^-?[0-9]+$ ]]; then
        echo "Error: File '$filename' does not contain a valid integer." >&2
        return 1
    fi

    # 5. Increment the number and overwrite the file with the new value.
    echo "$((number + 1))" > "$filename"
}

./stgit.sh create br1
increment_file_number file1
git commit -am "increment file1"
git push origin br1
./stgit.sh create br2
increment_file_number file1
git commit -am "increment file1"
git push origin br2