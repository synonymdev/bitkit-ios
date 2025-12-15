#!/usr/bin/env python3
"""
Add explicit Swift file references to the Xcode project.
This fixes the PBXFileSystemSynchronizedRootGroup issue with command-line builds.
"""

import os
import re
import hashlib

def generate_id(seed):
    """Generate a deterministic 24-character hex ID from a seed string."""
    return hashlib.md5(seed.encode()).hexdigest()[:24].upper()

def main():
    project_path = '/Users/john/bitkit-ios/Bitkit.xcodeproj/project.pbxproj'
    bitkit_dir = '/Users/john/bitkit-ios/Bitkit'
    
    # Find all Swift files
    swift_files = []
    for root, dirs, files in os.walk(bitkit_dir):
        # Skip Preview Content and PaykitIntegration (those have their own handling)
        if 'Preview Content' in root:
            continue
        for f in files:
            if f.endswith('.swift'):
                full_path = os.path.join(root, f)
                rel_path = os.path.relpath(full_path, '/Users/john/bitkit-ios')
                swift_files.append(rel_path)
    
    print(f"Found {len(swift_files)} Swift files")
    
    # Read project file
    with open(project_path, 'r') as f:
        content = f.read()
    
    # Check if we already added explicit sources
    if 'EXPLICIT_SOURCE_' in content:
        print("Explicit sources already added. Skipping.")
        return
    
    # Generate file references and build files
    file_refs = []
    build_files = []
    build_file_ids = []
    
    for swift_file in sorted(swift_files):
        file_name = os.path.basename(swift_file)
        ref_id = generate_id(f"EXPLICIT_SOURCE_REF_{swift_file}")
        build_id = generate_id(f"EXPLICIT_SOURCE_BUILD_{swift_file}")
        
        # PBXFileReference
        file_refs.append(f'\t\t{ref_id} /* {file_name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{swift_file}"; sourceTree = SOURCE_ROOT; }};')
        
        # PBXBuildFile
        build_files.append(f'\t\t{build_id} /* {file_name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {file_name} */; }};')
        build_file_ids.append(f'\t\t\t\t{build_id} /* {file_name} in Sources */,')
    
    # Insert file references before "/* End PBXFileReference section */"
    file_ref_marker = '/* End PBXFileReference section */'
    file_refs_str = '\n'.join(file_refs) + '\n'
    content = content.replace(file_ref_marker, file_refs_str + file_ref_marker)
    
    # Insert build files before "/* End PBXBuildFile section */"
    build_file_marker = '/* End PBXBuildFile section */'
    build_files_str = '\n'.join(build_files) + '\n'
    content = content.replace(build_file_marker, build_files_str + build_file_marker)
    
    # Add files to Bitkit Sources build phase (96FE1F5D2C2DE6AA006D0C8B)
    sources_phase_pattern = r'(96FE1F5D2C2DE6AA006D0C8B /\* Sources \*/ = \{\s*isa = PBXSourcesBuildPhase;\s*buildActionMask = \d+;\s*files = \()(\s*\);)'
    build_file_ids_str = '\n' + '\n'.join(build_file_ids) + '\n\t\t\t'
    content = re.sub(sources_phase_pattern, r'\1' + build_file_ids_str + r'\2', content)
    
    # Write updated project file
    with open(project_path, 'w') as f:
        f.write(content)
    
    print(f"✅ Added {len(swift_files)} Swift files to project")
    print("✅ Added file references")
    print("✅ Added build files")
    print("✅ Updated Sources build phase")

if __name__ == '__main__':
    main()

