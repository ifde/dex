from flask import Flask, request, send_file, jsonify, render_template
import zipfile
import io
import os
import shutil
import re

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
    zip_file.writestr('README.md', f'# {hook_name} Project\n\nInstructions for deployment.')

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

if __name__ == '__main__':
    app.run(debug=True)