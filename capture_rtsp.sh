#!/bin/bash

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Load RTSP uris =========================================================================================================================
# Loop through command line arguments and validate RTSP URIs
for rtsp_uri in "$@"; do
  # Validate the RTSP URI format
  if [[ "$rtsp_uri" =~ ^rtsp:// ]]; then
    RTSP_URIS+=("$rtsp_uri")
  else
    echo "Invalid RTSP URI format: $rtsp_uri. Please provide a valid RTSP URI."
    echo "Example RTSP URI: rtsp://example.com:8554/stream"
  fi
done

#  Validate the RTSP URI format
if [ ${#RTSP_URIS[@]} -eq 0 ]; then
  echo "No valid RTSP URIs provided."
  exit 1
fi

# Display the number of valid RTSP URIs and their names
echo "Number of valid RTSP URIs: ${#RTSP_URIS[@]}"
# echo "Valid RTSP URIs:"
# for valid_uri in "${RTSP_URIS[@]}"; do
#   echo "$valid_uri"
# done

# End of Load RTSP uris =========================================================================================================================

# Calculate the maximum number of lines allowed in a CSV file based on the number of RTSP URIs
# buffer = stream * n_rtcp_packets * 15 rtp_packets. eg : 1*5*10=50
MAX_LINES=$((2000 * ${#RTSP_URIS[@]}))

# =========================================================================================================================
# Define functions  ======================================================================================================= 

# directory of logging files
DIR_LOG="logs_rtsp"
DIR_LOG="/tmp/"
mkdir -p $DIR_LOG

# Cleanup function
cleanup() {
    # Check and kill each process if it's running
    [ -n "$RTSP_PID" ] && kill "$RTSP_PID" 2>/dev/null

    # Also, clean up any RTSP source processes that were started
    for PID in "${RTSP_SRC_PIDS[@]}"; do
        [ -n "$PID" ] && kill "$PID" 2>/dev/null
    done
}

# Register the cleanup function to be called on script interruption
trap cleanup EXIT SIGINT SIGTERM SIGPIPE


# Capture RTSP Packets 

# Function to capture RTSP data
# tshark command : tshark -z rtsp,state -Y "rtcp.pt==200 || (rtp.p_type==96 && rtp.marker==1)"
#                         -T fields -E header=y -E separator=, -E quote=d -E occurrence=f 
#                         -e frame.time_epoch -e rtcp.senderssrc -e rtcp.timestamp.ntp.msw -e rtcp.timestamp.ntp.lsw -e rtcp.timestamp.rtp

cmd_capture_rtsp() {
    local con_display="rtcp.pt==200 || (rtp.p_type==96 && rtp.marker==1)"
    local fields_extension=(
        "-E" "header=y" 
        "-E" "separator=," 
        "-E" "occurrence=f")
    local fields_rtcp=(
        "-e" "frame.time_epoch" 
        "-e" "rtcp.senderssrc"
        "-e" "rtcp.timestamp.ntp.msw"
        "-e" "rtcp.timestamp.ntp.lsw"
        "-e" "rtcp.timestamp.rtp")
    local fields_rtp=(
        "-e" "rtp.ssrc"
        "-e" "udp.port"
        "-e" "rtp.timestamp"
        "-e" "rtp.marker")
    local cmd1=("stdbuf" "--output=L"  
                "tshark" 
                "-z" "rtsp,state"  
                "-Y" "$con_display"  
                    "-T" "fields"  
                        "${fields_extension[@]}"  
                        "${fields_rtcp[@]}"  
                        "${fields_rtp[@]}")
    # Print the command to the terminal
    echo "Command of Capture rtcp : ${cmd1[@]} "
    
    # Execute the command and redirect output to the buffer
    "${cmd1[@]}" 2>errlog1 1> $DIR_LOG/rtsp_capture_$TIMESTAMP.csv

}

# Function to establish RTSP connection
cmd_rtspsrc() {
  local cmd=("gst-launch-1.0" "rtspsrc" "location=$rtsp_uri" "!" "fakesink")
  echo "Command to Recive rtsp Stream: ${cmd[@]}" 
  # Execute the command
  "${cmd[@]}"
}



# Function to manage the size of CSV files
manage_csv_size() {
  local file="$1"
  local full_path="$DIR_LOG/$file"

  # Check if the file exists
  if [ -f "$full_path" ]; then
    line_count=$(wc -l < "$full_path")

    # If the file size exceeds the maximum limit, keep only the latter half of it
    if [ "$line_count" -gt "$MAX_LINES" ]; then
      (
        # Acquire a lock on the file
        exec 9<"$full_path"
        flock 9

        # Save the header of the file
        header=$(head -n 1 "$full_path")

        # Use awk to print the header and the last MAX_LINES/2 lines
        awk -v max_lines="$MAX_LINES" '
          NR == 1 {
            next
          }
          NR > max_lines/2 + 1 { 
            print prev_line
          } 
          { 
            prev_line = $0
          }
        ' "$full_path" > "$DIR_LOG/tmp_$file"

        # Concatenate the header and the content
        echo "$header" > "$full_path"
        cat "$DIR_LOG/tmp_$file" >> "$full_path"
        rm "$DIR_LOG/tmp_$file"

        # Release the lock on the file and close the file descriptor
        flock -u 9
        exec 9>&-
      ) 
    fi
  else
    echo "Warning: $full_path does not exist."
  fi
}

# Function to move CSV files to the backup directory
move_csv_to_backup() {
  # Create the backup directory if it doesn't exist
  mkdir -p "$DIR_LOG/backup"
  
  # List all CSV files in the main log directory
  csv_files=("$DIR_LOG"/*.csv)
  
  if [ ${#csv_files[@]} -gt 0 ]; then
    # Move each CSV file to the backup directory
    for csv_file in "${csv_files[@]}"; do
      mv "$csv_file" "$DIR_LOG/backup"
    done
  fi
}

# Function to keep only the latest 10 backup CSV files
manage_backup_files() {
  backup_files=("$DIR_LOG/backup"/*.csv)
  
  # Check the number of backup files
  num_files=${#backup_files[@]}
  
  # If there are more than 10 files, delete the older ones to keep only 10
  if [ "$num_files" -gt 10 ]; then
    # Sort files by modification time (oldest first)
    IFS=$'\n' sorted_files=($(ls -rt "${backup_files[@]}"))
    
    # Calculate the number of files to delete
    num_files_to_delete=$((num_files - 10))
    
    # Delete the older files
    for ((i = 0; i < num_files_to_delete; i++)); do
      rm "${sorted_files[$i]}"
    done
  fi
}
# =========================================================================================================================

# =========================================================================================================================
# Startup command =========================================================================================================

# Move existing CSV files to the backup directory at the beginning
move_csv_to_backup

# Manage the number of backup CSV files
manage_backup_files


(cmd_capture_rtsp) & RTSP_PID=$!
 

# Check if each process started successfully
for PID in "$RTSP_PID" ; do
    retries=0
    max_retries=10  # set max retries

    while true; do
        if kill -0 "$PID" 2>/dev/null; then
            echo "Capture process for PID $PID has started."
            break
        fi

        retries=$((retries + 1))
        if [ "$retries" -ge "$max_retries" ]; then
            echo "Error starting a capture process for PID $PID."
            cleanup
            exit 1
        fi

        sleep 1
    done
done
echo "All capture processes have started successfully."

# Begin RTSP connection
RTSP_SRC_PIDS=()
# Loop through each RTSP URI and perform actions
for rtsp_uri in "${RTSP_URIS[@]}"; do
  echo "rtsp uri : $rtsp_uri"
  # Begin RTSP connection for the current URI
  cmd_rtspsrc "$rtsp_uri" &
  RTSP_SRC_PID=$!
  RTSP_SRC_PIDS+=("$RTSP_SRC_PID")  # Store the PID in an array
  sleep 1
done

# Clear tmp*.pcapng
rm -v $DIR_LOG*.pcapng

# Acquire a lock on the file descriptor 9
flock 9

# Periodically manage the size of the CSV files
while true; do
  # Calculate the sleep duration based on the number of RTSP URIs
  sleep_duration=$((6 / ${#RTSP_URIS[@]}))
  sleep "$sleep_duration"

  # Check if the main processes are still running, and if not, exit the loop
  if ! kill -0 "$RTSP_PID" 2>/dev/null ; then
    echo "One or more capture processes are no longer running. Exiting loop."
    cleanup
    exit 1
  fi

  # Manage the size of CSV files
  manage_csv_size "rtsp_capture_$TIMESTAMP.csv"

done
 
# Release the lock on the file descriptor 9
flock -u 9

echo "Script execution completed."