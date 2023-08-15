import os
import sys
import glob
import datetime
import numpy as np
import pandas as pd
from typing import Union

# Constants
NTP_EPOCH = 1900
UNIX_EPOCH = 1970
# Calculate the number of seconds between the NTP and UNIX epochs.
SEC_BETWEEN_EPOCHS = ( (70 - 17) * 365 + 17 * 366 ) * 24 * 60 * 60 # 2208988800

SAMPLE_RATE = 9e4  # 90kHz for video sample rate

def ntp2unix(ntp_timestamp_msw: Union[str, int], ntp_timestamp_lsw: Union[str, int]) -> float:
    """
    Convert NTP timestamp format to UNIX timestamp.
    
    Parameters:
    - ntp_timestamp_msw: Most significant word (integer part) of the NTP timestamp.
    - ntp_timestamp_lsw: Least significant word (fractional part) of the NTP timestamp.
    
    Returns:
    - UNIX timestamp
    """
    
    # Convert input strings to integers if necessary
    try:
        ntp_timestamp_msw = int(ntp_timestamp_msw)
        ntp_timestamp_lsw = int(ntp_timestamp_lsw)
    except ValueError:
        raise ValueError("Invalid inputs for NTP timestamps. They should be convertible to integers.")
    
    # Calculate seconds from the NTP epoch
    ntp_seconds = ntp_timestamp_msw + (ntp_timestamp_lsw / 2**32)

    # Convert to UNIX epoch by subtracting the seconds offset between NTP and UNIX epochs
    unix_timestamp = ntp_seconds - SEC_BETWEEN_EPOCHS
    
    return unix_timestamp

 

def unix2ntp(unix_timestamp: Union[str, float, int]) -> float:
    """
    Convert UNIX timestamp to NTP timestamp format.
    
    Parameters:
    - unix_timestamp: UNIX timestamp (seconds since epoch)
    
    Returns:
    - NTP timestamp (as a floating-point number, where the integer part represents
      the most significant word (seconds since NTP epoch) and the fractional part 
      represents the least significant word).
    """
    
    # Convert input string to float if necessary
    try:
        unix_timestamp = float(unix_timestamp)
    except ValueError:
        raise ValueError("Invalid input for UNIX timestamp. It should be convertible to float.")

    
    # Convert UNIX timestamp to NTP timestamp by adding the seconds offset between 
    # NTP and UNIX epochs
    ntp_timestamp = unix_timestamp - SEC_BETWEEN_EPOCHS
    
    return ntp_timestamp


def unix_to_local(unix_timestamp: Union[str, float, int]) -> str:
    """
    Convert UNIX timestamp to local datetime.

    Parameters:
    - unix_timestamp: UNIX timestamp (seconds since epoch)

    Returns:
    - Local datetime in string format as 'YYYY-MM-DD HH:MM:SS'
    """
    # Convert input string to float if necessary
    try:
        unix_timestamp = float(unix_timestamp)
    except ValueError:
        raise ValueError("Invalid input for UNIX timestamp. It should be convertible to float.")
    
    # Convert the UNIX timestamp to local datetime and return as formatted string
    return datetime.datetime.fromtimestamp(unix_timestamp).strftime('%Y-%m-%d %H:%M:%S')

def get_rtsp_latency(ts_sender_unix: float, 
                     rtp_ts_sender: float, 
                     ts_received: float, 
                     rtp_ts_received: float, 
                     sample_rate: float=SAMPLE_RATE) -> float:
    """
    Calculate RTSP latency based on the provided RTP timestamps and the received timestamp.
    
    Parameters:
    - rtp_ts_sender: RTP timestamp when the video frame was sent.
    - rtp_ts_received: RTP timestamp when the video frame was received.
    - ts_received: Timestamp when the video frame was received.
    
    Returns:
    - RTSP latency in seconds.
    """

    # Latency Counting
    sample_rate = 9e4  # 90kHz for video sample rate
    rtp_ts_diff = rtp_ts_sender - rtp_ts_received
    time_diff = rtp_ts_diff / sample_rate
    ts_sender_mapped = ts_sender_unix + time_diff
    
    latency = ts_received - ts_sender_mapped  # in seconds
    
    return latency

def map_sender_timestamp(ts_sender_unix_: float, 
                         rtp_ts_sender_: int, 
                         rtp_ts_received_: int) -> float:
    """
    Map the sender's timestamp based on RTP timestamp differences.
    
    Parameters:
    - ts_sender_unix_ : float
        UNIX timestamp of the sender obtained from the RTCP capture.
        
    - rtp_ts_sender_ : int
        RTP timestamp from the sender obtained from the RTCP capture.
        
    - rtp_ts_received_ : int
        RTP timestamp of the received packet obtained from the RTP capture.
        
    Returns:
    - ts_sender_mapped : float
        Mapped UNIX timestamp of the sender considering the RTP timestamp difference.
    """
    
    # Ensure SAMPLE_RATE is defined. Using a default value here, but you might want to
    # pass this as an argument to the function or define it globally in your script.
    SAMPLE_RATE = 9e4  # 90kHz for video sample rate. Define appropriately if different.
    
    try:
        rtp_ts_diff = rtp_ts_received_ - rtp_ts_sender_
        time_diff = rtp_ts_diff / SAMPLE_RATE
        ts_sender_mapped = ts_sender_unix_ + time_diff
        return ts_sender_mapped
    except ZeroDivisionError:
        raise ValueError("SAMPLE_RATE cannot be zero.")
    except Exception as e:
        raise RuntimeError(f"An error occurred while mapping the sender timestamp: {e}")

def find_recent_file(file_prefix: str='rtp_capture',dir_log :str='logs_rtsp')->str:
    matching_files = glob.glob(os.path.join(dir_log, f"{file_prefix}*.csv"))
    latest_file = max(matching_files, key=os.path.getmtime, default=None)

    if latest_file:
        print(f'Find the latest_file : {latest_file}')
        return latest_file
    else:
        print(f"No '{file_prefix}_*.csv' files found in the directory.")