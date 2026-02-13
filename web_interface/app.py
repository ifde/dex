from flask import Flask, request, send_file, jsonify, render_template, send_from_directory
import zipfile
import io
import os
import shutil
import re
import subprocess
import json
from datetime import datetime, timezone
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

app = Flask(__name__)

# Path to project root (adjust if needed)
PROJECT_ROOT = os.path.join(os.path.dirname(__file__), '..')

def load_hooks():
    hooks = {}
    hook_files = ['BAHook.sol', 'DAHook.sol', 'ABHook.sol', 'MEVChargeHook.sol', 'PegStabilityHook.sol']
    src_dir = os.path.join(PROJECT_ROOT, 'src')
    for file in hook_files:
        file_path = os.path.join(src_dir, file)
        if os.path.exists(file_path):
            with open(file_path, 'r') as f:
                code = f.read()
            
        # Extract description from NatSpec (updated regex for multiline)
        description_match = re.search(r'/\*\*\s*\*\s*@title\s*(.*?)\s*\*\s*@notice\s*(.*?)\s*\*/', code, re.DOTALL)
        if description_match:
          description = description_match.group(2).strip()
          # Clean up: replace " * " with newlines for separate lines
          description = description.replace('*', '\n').replace('* ', '\n').strip()
        else:
          description = 'No description available.'

        # Extract parameters (updated patterns for flexibility)
        params = []
        param_patterns = {
            # Defaults and core constants
            'MALICIOUS_FEE_MAX_DEFAULT': r'uint(?:8|24|256)\s+(?:private|public)?\s+(?:constant\s+)?MALICIOUS_FEE_MAX_DEFAULT\s*=\s*([^;]+);',
            'FIXED_LP_FEE_DEFAULT':      r'uint(?:8|24|256)\s+(?:private|public)?\s+(?:constant\s+)?FIXED_LP_FEE_DEFAULT\s*=\s*([^;]+);',
            'MAX_COOLDOWN_SECONDS':      r'uint(?:8|24|256)\s+(?:private|public)?\s+(?:constant\s+)?MAX_COOLDOWN_SECONDS\s*=\s*([^;]+);',
            'FEE_DENOMINATOR':           r'uint(?:8|24|256)\s+(?:private|public)?\s+(?:constant\s+)?FEE_DENOMINATOR\s*=\s*([^;]+);',
            'MAX_BLOCK_OFFSET':          r'uint8\s+(?:private|public)?\s+(?:constant\s+)?MAX_BLOCK_OFFSET\s*=\s*([^;]+);',
            'MAX_LINK_DEPTH':            r'uint8\s+(?:private|public)?\s+(?:constant\s+)?MAX_LINK_DEPTH\s*=\s*([^;]+);',
            'FLAG_IS_FEE_ADDRESS':       r'uint8\s+(?:private|public)?\s+(?:constant\s+)?FLAG_IS_FEE_ADDRESS\s*=\s*([^;]+);',

            # Hook tuning constants
            'INITIAL_FEE':               r'uint24\s+(?:private|public)?\s+(?:constant\s+)?INITIAL_FEE\s*=\s*([^;]+);',
            'FSTEP':                     r'uint24\s+(?:private|public)?\s+(?:constant\s+)?FSTEP\s*=\s*([^;]+);',
            'MAX_FEE':                   r'uint24\s+(?:private|public)?\s+(?:constant\s+)?MAX_FEE\s*=\s*([^;]+);',
            'K':                         r'uint24\s+(?:private|public)?\s+(?:constant\s+)?K\s*=\s*([^;]+);',
            'A':                         r'uint256\s+(?:private|public)?\s+(?:constant\s+)?A\s*=\s*([^;]+);',

            # Public BPS bounds (PegStabilityHook etc.)
            'MAX_FEE_BPS':               r'uint24\s+(?:public|private)?\s+(?:constant\s+)?MAX_FEE_BPS\s*=\s*([^;]+);',
            'MIN_FEE_BPS':               r'uint24\s+(?:public|private)?\s+(?:constant\s+)?MIN_FEE_BPS\s*=\s*([^;]+);',
        }


        for param, pattern in param_patterns.items():
            match = re.search(pattern, code)
            if match:
                value = match.group(1)
                unit = 'bps' if 'FEE' in param or param == 'K' else ''
                params.append(f'{param}: {value} ({unit})')
            
            hook_name = file.replace('.sol', '')
            hooks[hook_name] = {
                'description': description,
                'params': params,
                'code': code
            }
    return hooks

# Load hooks at startup
HOOKS = load_hooks()

def create_base_zip(zip_file, hook_name, updated_code=''):
    """Create the base project structure in the ZIP."""
    # Add root files
    root_files = ['foundry.toml', 'remappings.txt', 'foundry.lock', '.gitignore', '.gitmodules', 'requirements.txt', 'fetch_binance_data.py']
    for file in root_files:
        src_path = os.path.join(PROJECT_ROOT, file)
        if os.path.exists(src_path):
            zip_file.write(src_path, file)
        else:
            zip_file.writestr(file, f'// Placeholder for {file}')
    
    # Add specific files to root from utils
    utils_files = ['web_interface/utils/init.sh', 'web_interface/utils/README.md']
    for file in utils_files:
        src_path = os.path.join(PROJECT_ROOT, file)
        if os.path.exists(src_path):
            zip_file.write(src_path, os.path.basename(file))  # Add to root
    
    # Add folders with actual content
    folders_to_copy = {
        'src/interfaces': 'src/interfaces/',
        'test/utils': 'test/utils/',
        'script/base': 'script/base/',
        'lib': 'lib/'
    }
    for src_folder, zip_folder in folders_to_copy.items():
        src_path = os.path.join(PROJECT_ROOT, src_folder)
        if os.path.exists(src_path):
            for root, dirs, files in os.walk(src_path):
                for file in files:
                    file_path = os.path.join(root, file)
                    arcname = os.path.join(zip_folder, os.path.relpath(file_path, src_path))
                    if arcname == 'test/utils/libraries/HookConstants.sol':
                        continue
                    zip_file.write(file_path, arcname)
        else:
            zip_file.writestr(zip_folder + 'placeholder', f'// Placeholder for {zip_folder}')

    
    # Modify HookConstants.sol to include only the selected hook
    hook_constants_src = os.path.join(PROJECT_ROOT, 'test/utils/libraries/HookConstants.sol')
    if os.path.exists(hook_constants_src):
        with open(hook_constants_src, 'r') as f:
            content = f.read()
        # Replace the array initialization and assignments with the single hook
        content = re.sub(
            r'string\[\] memory names = new string\[\]\(5\);\s*names\[0\] = "[^"]+";\s*names\[1\] = "[^"]+";\s*names\[2\] = "[^"]+";\s*names\[3\] = "[^"]+";\s*names\[4\] = "[^"]+";',
            f'string[] memory names = new string[](1);\n    names[0] = "{hook_name}";',
            content
        )
        zip_file.writestr('test/utils/libraries/HookConstants.sol', content)
    
    # Add specific files
    files_to_copy = {
    'test/testHook.t.sol': 'test/testHook.t.sol',
    'script/deployHook.s.sol': 'script/deployHook.s.sol'
    }
    for src_file, zip_file_path in files_to_copy.items():
        src_path = os.path.join(PROJECT_ROOT, src_file)
        if os.path.exists(src_path):
            zip_file.write(src_path, zip_file_path)
    
    # Add hook-specific file
    if hook_name in HOOKS:
        code_to_use = updated_code if updated_code else HOOKS[hook_name]['code']
        zip_file.writestr(f'src/{hook_name}.sol', code_to_use)
    
    # Add README (overwrite if exists)
    # zip_file.writestr('README.md', f'# {hook_name} Project\n\nInstructions for deployment.')

@app.route('/')
def index():
    return render_template('index.html', hooks=HOOKS)

@app.route('/select_hook', methods=['POST'])
def select_hook():
    hook_name = request.form['hook']
    hook_data = HOOKS.get(hook_name, {})
    description = hook_data.get('description', '').replace('\n', '<br>')
    return jsonify({
        'description': description,
        'params': hook_data.get('params', []),
        'code': hook_data.get('code', '')
    })

@app.route('/download/<hook_name>', methods=['GET', 'POST'])
def download(hook_name):
    if request.method == 'POST':
        updated_code = request.form.get('code', HOOKS.get(hook_name, {}).get('code', ''))
    else:
        updated_code = HOOKS.get(hook_name, {}).get('code', '')
    
    zip_buffer = io.BytesIO()
    with zipfile.ZipFile(zip_buffer, 'w', zipfile.ZIP_DEFLATED) as zip_file:
        create_base_zip(zip_file, hook_name, updated_code)
    
    zip_buffer.seek(0)
    return send_file(zip_buffer, mimetype='application/zip', as_attachment=True, download_name=f'{hook_name}_project.zip')

@app.route('/run_sim', methods=['POST'])
def run_sim():
    hook = request.form['hook']
    year = int(request.form['year'])
    month = int(request.form['month'])
    tokenA = request.form['tokenA'].upper()
    tokenB = request.form['tokenB'].upper()

    # 1) Fetch CSVs
    fetch_cmd = [
        "python", os.path.join(PROJECT_ROOT, "fetch_binance_data.py"),
        "--symbol1", tokenA,
        "--symbol2", tokenB,
        "--year", str(year), "--month", str(month)
    ]
    subprocess.check_call(fetch_cmd, cwd=PROJECT_ROOT)

    # 2) Run forge test
    env = os.environ.copy()
    env["HOOK_NAME"] = hook
    out_path = os.path.join(PROJECT_ROOT, "simulation_output.txt")
    forge_cmd = [
        "forge", "test", "--match-path", "test/Simulation.t.sol",
        "-vv", "--gas-limit", "100000000000"
    ]
    with open(out_path, "w") as f:
        subprocess.check_call(forge_cmd, cwd=PROJECT_ROOT, env=env, stdout=f, stderr=subprocess.STDOUT)

    # 3) Parse output
    summary, swaps = parse_sim_output(out_path)

    images = generate_swap_graphs(swaps, tokenA, tokenB)

    return jsonify({"summary": summary, "images": images})

@app.route('/static/<path:filename>')
def serve_static(filename):
    return send_from_directory(os.path.join(app.root_path, 'static'), filename)

def generate_swap_graphs(swaps, tokenA, tokenB):
    images = []
    if not swaps:
        return images  # Empty list if no swaps

    # Separate data for A->B and B->A
    ab_nums, ab_amounts, ab_prices = [], [], []
    ba_nums, ba_amounts, ba_prices = [], [], []
    for s in swaps:
        if s['direction'] == 'A->B':
            ab_nums.append(s['num'])
            ab_amounts.append(s['amount_in'])
            ab_prices.append(s['priceA'])
        elif s['direction'] == 'B->A':
            ba_nums.append(s['num'])
            ba_amounts.append(s['amount_in'])
            ba_prices.append(s['priceB'])

    static_dir = os.path.join(app.root_path, 'static')
    os.makedirs(static_dir, exist_ok=True)

    old_images = ['a_price_graph.png', 'b_price_graph.png', 'shib_eth_ratio_graph.png', 'pool_price_graph.png']
    for img in old_images:
        img_path = os.path.join(static_dir, img)
        if os.path.exists(img_path):
            os.remove(img_path)

    timestamp = datetime.now(timezone.utc).timestamp()
    

    # Image 1: A Prices
    if swaps:
        plt.figure(figsize=(12, 6))
        nums = [s['num'] for s in swaps]
        pricesA = [s['priceA'] / 100000000 for s in swaps]  # Divide by 10^8
        plt.plot(nums, pricesA, marker='o', markersize=6, linestyle='-', color='purple', label=f'{tokenA} CEX Price')
        plt.title(f'CEX Prices Over Time: {tokenA}')
        plt.xlabel('Swap #')
        plt.ylabel('Price (USD)')
        plt.legend()
        plt.grid(True)
        max_num = max(nums)
        plt.xlim(0, max_num * 1.1)
        plt.xticks(range(0, max_num + 1, max(1, max_num // 20)))
        a_price_path = os.path.join(static_dir, 'a_price_graph.png')
        plt.savefig(a_price_path)
        plt.close()
        images.append({"title": f"CEX Prices: {tokenA}", "path": f'/static/a_price_graph.png?timestamp={timestamp}'})

    # Image 2: B Prices
    if swaps:
        plt.figure(figsize=(12, 6))
        nums = [s['num'] for s in swaps]
        pricesB = [s['priceB'] / 100000000 for s in swaps]  # Divide by 10^8
        plt.plot(nums, pricesB, marker='s', markersize=6, linestyle='-', color='brown', label=f'{tokenB} CEX Price')
        plt.title(f'CEX Prices Over Time: {tokenB}')
        plt.xlabel('Swap #')
        plt.ylabel('Price (USD)')
        plt.legend()
        plt.grid(True)
        max_num = max(nums)
        plt.xlim(0, max_num * 1.1)
        plt.xticks(range(0, max_num + 1, max(1, max_num // 20)))
        b_price_path = os.path.join(static_dir, 'b_price_graph.png')
        plt.savefig(b_price_path)
        plt.close()
        images.append({"title": f"CEX Prices: {tokenB}", "path": f'/static/b_price_graph.png?timestamp={timestamp}'})

    # Image 3: SHIB/ETH CEX Ratio
    if swaps:
        plt.figure(figsize=(12, 6))
        nums = [s['num'] for s in swaps]
        ratios = [s['priceB'] / s['priceA'] for s in swaps]  # SHIB/ETH ratio (priceB and priceA are scaled by 10^8, so ratio is correct)
        plt.plot(nums, ratios, marker='o', markersize=6, linestyle='-', color='purple', label='SHIB/ETH Ratio')
        plt.title(f'SHIB/ETH CEX Ratio Over Time')
        plt.xlabel('Swap #')
        plt.ylabel('SHIB/ETH Ratio')
        plt.legend()
        plt.grid(True)
        max_num = max(nums)
        plt.xlim(0, max_num * 1.1)
        plt.xticks(range(0, max_num + 1, max(1, max_num // 20)))
        ratio_path = os.path.join(static_dir, 'shib_eth_ratio_graph.png')
        plt.savefig(ratio_path)
        plt.close()
        images.append({"title": "SHIB/ETH CEX Ratio", "path": f'/static/shib_eth_ratio_graph.png?timestamp={timestamp}'})

    # Image 4: Pool Price Changes
    if swaps:
        plt.figure(figsize=(12, 6))
        nums = [s['num'] for s in swaps]
        pool_prices = [s['poolPrice'] / 100000000 for s in swaps]  # Already scaled by 10^8 in Solidity
        plt.plot(nums, pool_prices, marker='^', markersize=6, linestyle='-', color='black', label='Pool Price')
        plt.title(f'Pool Price Changes: {tokenB}/{tokenA} Ratio')
        plt.xlabel('Swap #')
        plt.ylabel('Pool Price (scaled)')
        plt.legend()
        plt.grid(True)
        max_num = max(nums)
        plt.xlim(0, max_num * 1.1)
        plt.xticks(range(0, max_num + 1, max(1, max_num // 20)))
        pool_price_path = os.path.join(static_dir, 'pool_price_graph.png')
        plt.savefig(pool_price_path)
        plt.close()
        images.append({"title": f"Pool Price Changes: {tokenB}/{tokenA}", "path": f'/static/pool_price_graph.png?timestamp={timestamp}'})

    return images

def parse_sim_output(path):
    summary_lines = []
    swaps = []
    in_summary = False
    collecting_summary = False

    k = 0
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if line.startswith("=== SUMMARY ==="):
                in_summary = True
                collecting_summary = True
                continue  # Skip the header line
            if line.startswith("=== END ==="):
                collecting_summary = False
                break
            if collecting_summary:
                summary_lines.append(_scale_summary_line(line))
            elif line.startswith("Swap #"):
                if k == 0:
                    print(f"Parsed swap line: {_parse_swap(line)}")
                    k += 1
                swaps.append(_parse_swap(line))
    print(f"Length of swaps: {len(swaps)}")
    return "\n".join(summary_lines), swaps

def _scale_summary_line(line):
    # Scale large numbers (e.g., Volume, Fees) by dividing by 1e18 for readability
    # Example: "Volume: 11486891000000000000000" -> "Volume: 11486.891"
    patterns = [
        (r'(Volume|Fees|Initial Token[01]|Final Token[01]|Total Fees Gained - Token[01]|Holding Value|LP Value|Impermanent Loss|Effective Impermanent Loss): (\d+)', lambda m: f"{m.group(1)}: {int(m.group(2)) / 1e18:.3f}"),
        (r'(Swaps|Price updates|Impermanent Loss|Effective Impermanent Loss|Net Loss): (\d+)', lambda m: f"{m.group(1)}: {m.group(2)}"),  # No scaling for counts
    ]
    for pattern, replacer in patterns:
        match = re.search(pattern, line)
        if match:
            return replacer(match)
    return line

def _parse_swap(line):
    # Parse into dict: {"num": 1, "direction": "A->B", "amount_in": 0.1, "priceAB": 228396000000, "priceBA": 1036}
    # Amounts are already scaled by 1e18 in _scale_swap, but we parse as float
    parts = line.split()
    num = int(parts[1][1:])  # "Swap #1" -> 1
    direction = parts[2]  # "A->B"
    amount_in = float(parts[3].split('=')[1])  # "in=0.100000" -> 0.1
    priceAB = int(parts[4].split('=')[1])
    priceBA = int(parts[5].split('=')[1])
    poolPrice = int(parts[6].split('=')[1])
    return {"num": num, "direction": direction, "amount_in": amount_in, "priceA": priceAB, "priceB": priceBA, "poolPrice": poolPrice}

if __name__ == '__main__':
    app.run(debug=True)