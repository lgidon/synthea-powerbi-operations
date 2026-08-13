#!/usr/bin/env python3
"""
00_download_synthea.py

Downloads official Synthea sample datasets (1,000 synthetic patient records)
and extracts the raw CSV files directly into the data/raw/ directory.
"""

import os
import sys
import shutil
import urllib.request
import zipfile
from pathlib import Path

# Configuration
SYNTHEA_SAMPLE_URL = (
    "https://synthetichealth.github.io/synthea-sample-data/downloads/"
    "synthea_sample_data_csv_nov2021.zip"
)
PROJECT_ROOT = Path(__file__).resolve().parent.parent
RAW_DATA_DIR = PROJECT_ROOT / "data" / "raw"
TEMP_ZIP_PATH = RAW_DATA_DIR / "synthea_sample_latest.zip"


def create_directories():
    """Ensure raw data directory exists and is clean."""
    print(f"📁 Ensuring directory exists: {RAW_DATA_DIR}")
    RAW_DATA_DIR.mkdir(parents=True, exist_ok=True)


def download_progress(block_num, block_size, total_size):
    """Callback function to display download progress in terminal."""
    downloaded = block_num * block_size
    if total_size > 0:
        percent = min(100, int(downloaded * 100 / total_size))
        mb_downloaded = downloaded / (1024 * 1024)
        mb_total = total_size / (1024 * 1024)
        sys.stdout.write(
            f"\r⏳ Downloading: {percent}% [{mb_downloaded:.2f} MB / {mb_total:.2f} MB]"
        )
    else:
        sys.stdout.write(f"\r⏳ Downloading: {downloaded / (1024 * 1024):.2f} MB")
    sys.stdout.flush()


def download_synthea_archive():
    """Download the official zip bundle from Synthea's GitHub releases."""
    print(f"🌐 Fetching Synthea dataset from: {SYNTHEA_SAMPLE_URL}")
    try:
        urllib.request.urlretrieve(
            SYNTHEA_SAMPLE_URL, TEMP_ZIP_PATH, reporthook=download_progress
        )
        print("\n✅ Download completed successfully.")
    except Exception as e:
        print(f"\n❌ Error downloading Synthea dataset: {e}")
        sys.exit(1)


def extract_and_flatten_csvs():
    """Extract zip archive and flatten any nested folder paths into data/raw/."""
    print(f"📦 Extracting archives to: {RAW_DATA_DIR}")

    with zipfile.ZipFile(TEMP_ZIP_PATH, "r") as zip_ref:
        zip_ref.extractall(RAW_DATA_DIR)

    # Clean up the zip file after extraction
    if TEMP_ZIP_PATH.exists():
        TEMP_ZIP_PATH.unlink()

    # Move files out of any extracted subdirectories (e.g., csv/ or synthea_sample.../) into raw/
    extracted_items = list(RAW_DATA_DIR.iterdir())
    for item in extracted_items:
        if item.is_dir():
            for nested_file in item.glob("*.csv"):
                target_path = RAW_DATA_DIR / nested_file.name
                shutil.move(str(nested_file), str(target_path))
            # Remove empty folder after moving files
            shutil.rmtree(item)

    csv_count = len(list(RAW_DATA_DIR.glob("*.csv")))
    print(f"🎉 Extracted {csv_count} CSV files directly into {RAW_DATA_DIR}")


def main():
    print("=" * 60)
    print("🏥 Synthea Sample Data Ingestion Script")
    print("=" * 60)

    create_directories()
    
    # Skip download if files are already present
    existing_csvs = list(RAW_DATA_DIR.glob("*.csv"))
    if existing_csvs:
        print(
            f"ℹ️  Found {len(existing_csvs)} CSV files already present in {RAW_DATA_DIR}."
        )
        response = input("Re-download and overwrite? (y/N): ").strip().lower()
        if response != "y":
            print(" Skipping download step.")
            return

    download_synthea_archive()
    extract_and_flatten_csvs()
    print("\n✨ Ready for DuckDB staging phase!")


if __name__ == "__main__":
    main()