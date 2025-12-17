import requests
import csv
import os

def fetch_klines(symbol, interval='1m', limit=100):
    url = f'https://api.binance.com/api/v3/klines?symbol={symbol}&interval={interval}&limit={limit}'
    response = requests.get(url)
    response.raise_for_status()
    return response.json()

def save_to_csv(symbol, data):
    filename = f'{symbol}-1m-latest.csv'
    with open(filename, 'w', newline='') as f:
        writer = csv.writer(f)
        for kline in data:
            # Write: openTime, open, high, low, close, volume (matching test expectations)
            writer.writerow([kline[0], kline[1], kline[2], kline[3], kline[4], kline[5]])
    print(f'Saved {len(data)} klines to {filename}')

if __name__ == '__main__':
    # Fetch and save for ETHUSDT
    eth_data = fetch_klines('ETHUSDT')
    save_to_csv('ETHUSDT', eth_data)
    
    # Fetch and save for SHIBUSDT
    shib_data = fetch_klines('SHIBUSDT')
    save_to_csv('SHIBUSDT', shib_data)