import requests
import csv
import os
import argparse
from datetime import datetime, timezone

def fetch_klines(symbol, interval='1m', limit=1000, start_time=None, end_time=None):
    url = f'https://api.binance.com/api/v3/klines?symbol={symbol}&interval={interval}&limit={limit}'
    if start_time:
        url += f'&startTime={start_time}'
    if end_time:
        url += f'&endTime={end_time}'
    response = requests.get(url)
    response.raise_for_status()
    return response.json()

def save_to_csv(filename, data):
    with open(filename, 'w', newline='') as f:
        writer = csv.writer(f)
        for kline in data:
            # Write: openTime, open, high, low, close, volume (matching test expectations)
            writer.writerow([kline[0], kline[1], kline[2], kline[3], kline[4], kline[5]])
    print(f'Saved {len(data)} klines to {filename}')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Fetch Binance klines for a specific month.')
    parser.add_argument('--symbol1', default="ETHUSDT", help='First token pair (e.g., ETHUSDT)')
    parser.add_argument('--symbol2', default="SHIBUSDT", help='Second token pair (e.g., SHIBUSDT)')
    parser.add_argument('--year', type=int, default=2024, help='Year (default: 2024)')
    parser.add_argument('--month', type=int, default=1, help='Month (1-12, default: 1)')
    args = parser.parse_args()

    # Define the specific month. Default: January 2024
    start_date = datetime(args.year, args.month, 1, 0, 0, 0, tzinfo=timezone.utc)
    if args.month == 12:
        end_date = datetime(args.year + 1, 1, 1, 0, 0, 0, tzinfo=timezone.utc)
    else:
        end_date = datetime(args.year, args.month + 1, 1, 0, 0, 0, tzinfo=timezone.utc)
    start_time = int(start_date.timestamp() * 1000)  # ms
    end_time = int(end_date.timestamp() * 1000) - 1   # ms
    
    # Fetch and save for first symbol (to ETHUSDT-1m-latest.csv)
    data1 = fetch_klines(args.symbol1.upper(), start_time=start_time, end_time=end_time)
    save_to_csv('ETHUSDT-1m-latest.csv', data1)
    
    # Fetch and save for second symbol (to SHIBUSDT-1m-latest.csv)
    data2 = fetch_klines(args.symbol2.upper(), start_time=start_time, end_time=end_time)
    save_to_csv('SHIBUSDT-1m-latest.csv', data2)