import tkinter as tk
from tkinter import ttk, filedialog, messagebox
import os, plistlib, subprocess, requests, shutil, threading, time
# --- STYLING ---
BG_COLOR = "#1a1a1a"
FG_COLOR = "#e0e0e0"
ACCENT_COLOR = "#00e5ff"
BTN_COLOR = "#333333"
ALERT_COLOR = "#ff4b2b"
current_user = os.environ.get("SUDO_USER") or os.getlogin()
class MaschineMachineApp:
    def __init__(self, root):
        self.root = root
        self.root.title("Maschine Machine v1.1.15")
        self.root.configure(bg=BG_COLOR)
        self.sudo_active = False
        self.style = ttk.Style()
        self.style.theme_use('clam')
        self.configure_styles()
        self.create_main_menu()
        self.root.update_idletasks()
        self.root.resizable(False, False)
    def configure_styles(self):
        self.style.configure("TFrame", background=BG_COLOR)
        self.style.configure("TLabel", background=BG_COLOR, foreground=FG_COLOR, font=("Helvetica", 10))
        self.style.configure("TButton", background=BTN_COLOR, foreground=FG_COLOR, borderwidth=0, padding=10)
        self.style.map("TButton", background=[('active', ACCENT_COLOR)], foreground=[('active', '#000000')])
        self.style.configure("TProgressbar", thickness=15, troughcolor="#000000", background=ACCENT_COLOR)
        self.style.configure("Treeview", background="#111111", foreground=FG_COLOR, fieldbackground="#111111", borderwidth=0)
        self.style.map("Treeview", background=[('selected', ACCENT_COLOR)], foreground=[('selected', '#000000')])
    def create_main_menu(self):
        for widget in self.root.winfo_children():
            widget.destroy()
        tk.Label(self.root, text="MASCHINE MACHINE", font=("Helvetica", 24, "bold"), bg=BG_COLOR, fg=ACCENT_COLOR).pack(pady=(30, 5))
        tk.Label(self.root, text="Maschine Toolbox • Special Thanks to jointsmith", font=("Helvetica", 9), bg=BG_COLOR, fg="#555555").pack(pady=(0, 20))
        container = tk.Frame(self.root, bg=BG_COLOR)
        container.pack(fill="both", padx=50, pady=(0, 20))
        self.alert_label = tk.Label(container, text="⚠️ CHECK TERMINAL FOR PASSWORD ⚠️",
                                    font=("Helvetica", 10, "bold"), bg=BG_COLOR, fg=ALERT_COLOR)
        self.alert_label.pack(pady=5)
        self.alert_label.pack_forget()
        ttk.Button(container, text="SMART UNIFIED INSTALLER", width=40, command=self.on_smart_install).pack(pady=(5, 2))
        tk.Label(container, text="Installs ISOs, PKGs, or Library Folders", font=("Helvetica", 8), bg=BG_COLOR, fg="#777777").pack(pady=(0, 15))
        ttk.Button(container, text="MANUAL PAYLOAD EXTRACTOR", width=40, command=self.on_manual_extract).pack(pady=(5, 2))
        tk.Label(container, text="Dumps raw contents only (No Registration)", font=("Helvetica", 8), bg=BG_COLOR, fg="#777777").pack(pady=(0, 15))
        ttk.Button(container, text="REPAIR SYSTEM PERMISSIONS", width=40, command=self.repair_ni_permissions).pack(pady=(15, 5))
        tk.Label(self.root, text=f"Active User: {current_user}", bg=BG_COLOR, fg="#333333", font=("Helvetica", 8)).pack(side="bottom", pady=10)
    # --- PRIVILEGE MANAGEMENT ---
    def start_sudo_heartbeat(self):
        def heartbeat():
            while self.sudo_active:
                subprocess.run(['sudo', '-n', 'true'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                time.sleep(60)
        self.sudo_active = True
        threading.Thread(target=heartbeat, daemon=True).start()
    def preflight_sudo(self):
        self.alert_label.pack()
        self.root.update()
        result = subprocess.run(['sudo', '-v'])
        self.alert_label.pack_forget()
        self.root.update()
        if result.returncode == 0:
            self.start_sudo_heartbeat()
            return True
        return False
    def run_sudo_cmd(self, cmd, capture_errors=False):
        """Run a command with sudo. Returns (returncode, stderr_text). If not capture_errors, stderr_text is empty."""
        if capture_errors:
            r = subprocess.run(['sudo'] + cmd, capture_output=True, text=True)
            return (r.returncode, (r.stderr or "").strip())
        r = subprocess.run(['sudo'] + cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return (r.returncode, "")
    def set_permissions(self, path):
        self.run_sudo_cmd(['chown', '-R', f'{current_user}:staff', path])
        self.run_sudo_cmd(['chmod', '-R', 'u+rw', path])
    # --- INPUT PROMPTS ---
    def on_smart_install(self):
        messagebox.showinfo("Step 1: Source", "Select the folder containing your Library folders OR ISO/PKG installers.")
        src = filedialog.askdirectory(title="SELECT SOURCE")
        if not src: return
        messagebox.showinfo("Step 2: Destination", "Select where these libraries should be installed (e.g. /Users/Shared).")
        dst = filedialog.askdirectory(title="SELECT DESTINATION")
        if not dst or dst == "/": dst = "/Users/Shared"
        items = []
        for entry in os.listdir(src):
            if entry.startswith('.'): continue
            p = os.path.join(src, entry)
            if os.path.isdir(p): items.append({'name': entry, 'type': 'Folder', 'path': p})
            elif entry.lower().endswith(('.ISO', '.pkg')): items.append({'name': entry, 'type': 'ISO/PKG', 'path': p})
        if items:
            self.show_smart_list(items, dst, mode="install")
        else:
            messagebox.showwarning("No items", "No Library folders or ISO/PKG files found in the selected folder.")
    def on_manual_extract(self):
        messagebox.showinfo("Source", "Select the folder containing ISO/PKG files for raw extraction.")
        src = filedialog.askdirectory(title="SELECT SOURCE")
        if not src: return
        messagebox.showinfo("Extraction Destination", "Select where to dump the raw payloads.")
        dst = filedialog.askdirectory(title="SELECT EXTRACTION DESTINATION")
        if not dst: return
        items = [{'name': f, 'type': 'ISO/PKG', 'path': os.path.join(src, f)} for f in os.listdir(src) if f.lower().endswith(('.ISO', '.pkg'))]
        if items:
            self.show_smart_list(items, dst, mode="extract")
        else:
            messagebox.showwarning("No items", "No ISO or PKG files found in the selected folder.")
    def show_smart_list(self, items, dest_dir, mode):
        win = tk.Toplevel(self.root)
        win.title("Unified Expansion Queue")
        win.geometry("500x550")
        win.configure(bg=BG_COLOR)
        lbl = "Expansion Installation Queue:" if mode == "install" else "Manual Payload Extraction Queue:"
        tk.Label(win, text=lbl, bg=BG_COLOR, fg=ACCENT_COLOR, font=("Helvetica", 11, "bold")).pack(pady=15)
        tree = ttk.Treeview(win, columns=('name', 'type'), show='headings', height=15)
        tree.heading('name', text='Item Name'); tree.heading('type', text='Source Type')
        tree.column('name', width=340); tree.column('type', width=90, anchor='center')
        for i in items: tree.insert('', tk.END, values=(i['name'], i['type']))
        tree.pack(fill="both", expand=True, padx=20, pady=5)
        btn_txt = "START AUTO-INSTALL" if mode == "install" else "START RAW EXTRACTION"
        ttk.Button(win, text=btn_txt, command=lambda: self.run_batch(items, dest_dir, mode, win)).pack(pady=20)
    def run_batch(self, items, dest_dir, mode, win):
        win.destroy()
        if not self.preflight_sudo():
            return
        prog_win = tk.Toplevel(self.root)
        prog_win.geometry("500x160")
        prog_win.configure(bg=BG_COLOR)
        l = tk.Label(prog_win, text="Preparing...", bg=BG_COLOR, fg=FG_COLOR, wraplength=450)
        l.pack(pady=20)
        pb = ttk.Progressbar(prog_win, length=400, mode="determinate", maximum=len(items))
        pb.pack()
        all_errors = []
        # For multiple PKGs: collect XMLs from all first (like ISOs do)
        pkg_items = [item for item in items if item['type'] == 'ISO/PKG' and item['path'].lower().endswith('.pkg')]
        shared_xml = {}
        if len(pkg_items) > 1:
            for pkg_item in pkg_items:
                pkg_xmls = self.extract_xml_from_pkg(pkg_item['path'])
                shared_xml.update(pkg_xmls)
        for i, item in enumerate(items):
            l.config(text=f"Batch {i+1}/{len(items)}: {item['name']}")
            self.root.update()
            if mode == "install":
                if item['type'] == 'ISO/PKG':
                    # Use shared XML if available (multiple PKGs in folder)
                    use_xml = shared_xml if item['path'].lower().endswith('.pkg') and shared_xml else None
                    errs = self.process_installer(item['path'], dest_dir, True, use_xml)
                else:
                    errs = self.merge_expansion(item['path'], dest_dir, True, None)
            else:
                errs = self.process_installer(item['path'], dest_dir, False, None)
            for e in errs:
                all_errors.append(f"{item['name']}: {e}")
            pb["value"] = i + 1
            self.root.update()
        self.sudo_active = False
        prog_win.destroy()
        # Clean up XML cache
        xml_cache = "/tmp/ni_xml_cache"
        if os.path.exists(xml_cache):
            try:
                shutil.rmtree(xml_cache)
            except Exception:
                pass
        if all_errors:
            msg = "Some steps failed:\n\n" + "\n".join(all_errors[:15])
            if len(all_errors) > 15:
                msg += f"\n... and {len(all_errors) - 15} more."
            messagebox.showerror("Errors", msg)
        else:
            # Success: show summary of what was processed
            summary = f"Processed {len(items)} item(s) successfully.\n\n"
            summary += f"Library content copied to:\n{dest_dir}\n\n"
            if mode == "install":
                summary += "Registration files created at:\n"
                summary += "• /Library/Preferences/com.native-instruments.*.plist\n"
                summary += "• /Library/Application Support/Native Instruments/Service Center/*.xml\n"
                summary += "• /Users/Shared/NI Resources/image/*"
            messagebox.showinfo("Done", summary)
    def process_installer(self, path, dest, register, external_xml=None):
        """Returns list of error strings (empty if OK)."""
        path = os.path.abspath(path)
        if path.lower().endswith(".ISO"):
            res = subprocess.run(
                ['hdiutil', 'mount', '-nobrowse', '-readonly', path],
                capture_output=True, text=True
            )
            if res.returncode != 0:
                err = (res.stderr or res.stdout or "Unknown error").strip()
                return [f"Failed to mount ISO {os.path.basename(path)}: {err}"]
            mount_pt = None
            for line in (res.stdout or "").splitlines():
                if "/Volumes/" in line:
                    part = line.split("/Volumes/")[-1].strip().split("\t")[0].strip()
                    if part:
                        mount_pt = "/Volumes/" + part
                        break
            if not mount_pt or not os.path.isdir(mount_pt):
                return [f"Could not get mount point for ISO {os.path.basename(path)}"]
            errors = []
            # Verify we can read the mounted ISO
            try:
                iso_contents = os.listdir(mount_pt)
                if not iso_contents:
                    subprocess.run(['hdiutil', 'detach', mount_pt], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    return [f"ISO {os.path.basename(path)} appears empty after mounting"]
            except OSError as e:
                subprocess.run(['hdiutil', 'detach', mount_pt], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                return [f"Cannot read mounted ISO: {e}"]
            # For ISOs: first collect all XMLs from all PKGs, then process library folders
            # This ensures Part 1/2 can use XML from the main installer PKG
            pkg_files = []
            for root, dirs, files in os.walk(mount_pt):
                for f in files:
                    if f.lower().endswith(".pkg"):
                        pkg_files.append(os.path.join(root, f))
            pkg_found = len(pkg_files) > 0
            # First: scan ISO mount directly for XML files (in case PKG expansion fails)
            all_xml_from_pkgs = {}
            for root, dirs, files in os.walk(mount_pt):
                if "service center" in root.lower() or "service centre" in root.lower():
                    for f in files:
                        if f.lower().endswith(".xml"):
                            xml_path = os.path.join(root, f)
                            lib_name = os.path.splitext(f)[0]
                            all_xml_from_pkgs[lib_name.lower()] = xml_path
            # Then: expand all PKGs and collect any additional XMLs
            for pkg_file in pkg_files:
                pkg_xmls = self.extract_xml_from_pkg(pkg_file)
                all_xml_from_pkgs.update(pkg_xmls)
            # Now process each PKG with the combined XML collection
            for pkg_file in pkg_files:
                errs = self.expand_and_merge_with_xml(pkg_file, dest, register, all_xml_from_pkgs)
                errors.extend(errs)
            # Also process top-level folders on the ISO whose name contains "Library" (e.g. VintageHeat_Library)
            xml_on_mount = {}
            for root, dirs, files in os.walk(mount_pt):
                if "service center" in root.lower() or "service centre" in root.lower():
                    for f in files:
                        if f.lower().endswith(".xml"):
                            xml_path = os.path.join(root, f)
                            base = os.path.splitext(f)[0].lower()
                            # Add multiple key variations for flexible matching
                            xml_on_mount[base] = xml_path  # "vintage heat"
                            xml_on_mount[base.replace(" ", "")] = xml_path  # "vintageheat"
                            xml_on_mount[base.replace(" ", "_")] = xml_path  # "vintage_heat"
            lib_folders_on_iso = []
            try:
                all_entries = os.listdir(mount_pt)
                for entry in all_entries:
                    if entry.startswith("."):
                        continue
                    full = os.path.join(mount_pt, entry)
                    if os.path.isdir(full) and "library" in entry.lower():
                        lib_folders_on_iso.append(entry)
                        # Try multiple key formats to match XML: "VintageHeat_Library" -> try "vintageheat", "vintage heat", "vintage_heat"
                        base_name = entry.lower().replace("_library", "").replace(" library", "").strip()
                        xml_path = (xml_on_mount.get(base_name) or
                                   xml_on_mount.get(base_name.replace("_", "")) or
                                   xml_on_mount.get(base_name.replace("_", " ")))
                        errs = self.merge_expansion(full, dest, register, xml_path)
                        errors.extend(errs)
            except OSError as e:
                errors.append(f"Cannot list ISO root: {e}")
            # Report what was found
            if not pkg_found and not lib_folders_on_iso:
                errors.append(f"No .pkg files or Library folders found on ISO {os.path.basename(path)}")
            subprocess.run(['hdiutil', 'detach', mount_pt], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            # Clean up XML cache
            xml_cache = "/tmp/ni_xml_cache"
            if os.path.exists(xml_cache):
                try:
                    shutil.rmtree(xml_cache)
                except Exception:
                    pass
            if not pkg_found and not errors:
                errors.append(f"No .pkg file found inside ISO {os.path.basename(path)}")
            return errors
        # Single PKG file (not ISO) - use external XML if provided
        return self.expand_and_merge(path, dest, register, external_xml=external_xml)
    def extract_xml_from_pkg(self, pkg_path):
        """Extract and return XML files from a PKG. Returns dict {key: xml_path}."""
        xml_dict = {}
        temp = "/tmp/ni_unpack_xml"
        xml_cache = "/tmp/ni_xml_cache"
        if os.path.exists(temp):
            try:
                shutil.rmtree(temp)
            except Exception:
                return xml_dict
        if not os.path.exists(xml_cache):
            os.makedirs(xml_cache)
        pkg_path = os.path.abspath(pkg_path)
        res = subprocess.run(
            ['pkgutil', '--expand-full', pkg_path, temp],
            capture_output=True, text=True
        )
        if res.returncode != 0:
            # Fallback 1: try bundle package (directory)
            if os.path.isdir(pkg_path):
                try:
                    shutil.copytree(pkg_path, temp)
                except Exception:
                    return xml_dict
            else:
                # Fallback 2: try xar command
                xar_res = subprocess.run(
                    ['xar', '-xf', pkg_path, '-C', temp],
                    capture_output=True, text=True
                )
                if xar_res.returncode != 0:
                    # Check if xar extracted anything despite errors (partial extraction)
                    if not os.path.isdir(temp) or not os.listdir(temp):
                        return xml_dict
                    # Continue with partial extraction
        for root, dirs, files in os.walk(temp):
            if "service center" in root.lower() or "service centre" in root.lower():
                for f in files:
                    if f.lower().endswith('.xml'):
                        xml_src = os.path.join(root, f)
                        # Copy to cache so it persists after temp cleanup
                        xml_cached = os.path.join(xml_cache, f)
                        shutil.copy2(xml_src, xml_cached)
                        lib_name = os.path.splitext(f)[0]
                        xml_dict[lib_name.lower()] = xml_cached
        try:
            shutil.rmtree(temp)
        except Exception:
            pass
        return xml_dict
    def expand_and_merge_with_xml(self, pkg_path, dest_parent, register, external_xml):
        """Expand PKG and merge with externally provided XML dict."""
        return self.expand_and_merge(pkg_path, dest_parent, register, external_xml)
    def expand_and_merge(self, pkg_path, dest_parent, register, external_xml=None):
        """Returns list of error strings (empty if OK)."""
        errors = []
        temp = "/tmp/ni_unpack"
        if os.path.exists(temp):
            try:
                shutil.rmtree(temp)
            except Exception as e:
                errors.append(f"Could not clear temp dir: {e}")
                return errors
        pkg_path = os.path.abspath(pkg_path)
        # Try pkgutil --expand-full first
        res = subprocess.run(
            ['pkgutil', '--expand-full', pkg_path, temp],
            capture_output=True, text=True
        )
        if res.returncode != 0:
            # Fallback 1: some PKGs are bundle packages (directories) - try accessing directly
            if os.path.isdir(pkg_path):
                try:
                    shutil.copytree(pkg_path, temp)
                except Exception as e:
                    errors.append(f"Could not copy bundle package {os.path.basename(pkg_path)}: {e}")
                    return errors
            else:
                # Fallback 2: try xar command (some PKGs use xar format that pkgutil can't handle)
                xar_res = subprocess.run(
                    ['xar', '-xf', pkg_path, '-C', temp],
                    capture_output=True, text=True
                )
                if xar_res.returncode != 0:
                    # Check if xar extracted anything despite errors (partial extraction)
                    if not os.path.isdir(temp) or not os.listdir(temp):
                        err = (res.stderr or res.stdout or "Unknown error").strip()
                        errors.append(f"pkgutil failed for {os.path.basename(pkg_path)}: {err}")
                        return errors
        if not os.path.isdir(temp):
            errors.append(f"Extraction did not create output dir for {os.path.basename(pkg_path)}")
            return errors
        # Check if extraction produced any content
        try:
            temp_contents = os.listdir(temp)
            if not temp_contents:
                errors.append(f"Extraction succeeded but {os.path.basename(pkg_path)} is empty")
                return errors
        except OSError:
            errors.append(f"Cannot read extracted content from {os.path.basename(pkg_path)}")
            return errors
        # Extract XML files from Service Center folder if present
        xml_found = external_xml.copy() if external_xml else {}
        for root, dirs, files in os.walk(temp):
            if "service center" in root.lower() or "service centre" in root.lower():
                for f in files:
                    if f.lower().endswith('.xml'):
                        xml_path_pkg = os.path.join(root, f)
                        lib_name = os.path.splitext(f)[0]
                        xml_found[lib_name.lower()] = xml_path_pkg
        # Find library roots: name contains "library" OR directory contains PAResources (NI expansion layout)
        libs_found = []  # (root_path, display_name_for_registration)
        seen_paths = set()
        def is_ni_library_root(dir_path):
            return os.path.isdir(os.path.join(dir_path, "PAResources"))
        for root, dirs, files in os.walk(temp):
            for d in dirs:
                full = os.path.join(root, d)
                if full in seen_paths:
                    continue
                name_lower = d.lower()
                # Match "X Library" or "X Library Part 1" or "VintageHeatLibrary" etc.
                if "library" in name_lower:
                    lib_name = d.replace(" Library", "").replace(" library", "").strip()
                    if not lib_name:
                        lib_name = d
                    libs_found.append((full, lib_name))
                    seen_paths.add(full)
                    continue
                # No "library" in name: treat as library root if it contains PAResources (NI structure)
                if is_ni_library_root(full):
                    lib_name = d
                    libs_found.append((full, lib_name))
                    seen_paths.add(full)
        # Fallback: pkg name contains "Library" but payload folder has no "Library" in name (e.g. "Vintage Heat Library Part 1.pkg" -> folder "Vintage Heat")
        pkg_basename = os.path.basename(pkg_path).lower()
        if not libs_found and "library" in pkg_basename:
            skip_dirs = {"scripts", "resources", "__macosx", "contents", "packageinfo"}
            content_dirs = [d for d in os.listdir(temp) if not d.startswith(".") and os.path.isdir(os.path.join(temp, d)) and d.lower() not in skip_dirs]
            # Only use single content folder so we don't merge metadata-only pkgs (e.g. main installer with just Service Center)
            if len(content_dirs) == 1:
                inner_path = os.path.join(temp, content_dirs[0])
                # pkgutil often creates temp/SomeName.pkg/ or temp/Payload/ with real content one level down
                needs_deeper = content_dirs[0].lower().endswith(".pkg") or content_dirs[0].lower() == "payload"
                if needs_deeper:
                    inner_sub = [d for d in os.listdir(inner_path) if not d.startswith(".") and os.path.isdir(os.path.join(inner_path, d)) and d.lower() not in skip_dirs]
                    if len(inner_sub) == 1:
                        d = inner_sub[0]
                        libs_found.append((os.path.join(inner_path, d), d))
                    elif inner_sub:
                        # Multiple subdirs under Payload - use each as library root
                        for d in inner_sub:
                            libs_found.append((os.path.join(inner_path, d), d))
                    else:
                        libs_found.append((inner_path, content_dirs[0]))
                else:
                    libs_found.append((inner_path, content_dirs[0]))
        for lib_path, lib_name in libs_found:
            xml_for_lib = xml_found.get(lib_name.lower())
            errs = self.merge_expansion(
                lib_path, dest_parent, register,
                xml_for_lib
            )
            errors.extend(errs)
        try:
            shutil.rmtree(temp)
        except Exception:
            pass
        # Don't report error for installer/metadata-only pkgs (no library payload is expected)
        if not libs_found and not errors:
            name_lower = os.path.basename(pkg_path).lower()
            installer_only = "installer" in name_lower or "setup" in name_lower
            if not installer_only:
                errors.append(f"No library folder (name with 'Library' or dir with PAResources) found in {os.path.basename(pkg_path)}.")
        return errors
    def merge_expansion(self, src_path, dest_parent, register, xml_path=None):
        """Returns list of error strings (empty if OK)."""
        errors = []
        lib_name = os.path.basename(src_path)
        final_dest = os.path.join(dest_parent, lib_name)
        if not os.path.exists(final_dest):
            code, err = self.run_sudo_cmd(['mkdir', '-p', final_dest], capture_errors=True)
            if code != 0:
                errors.append(f"mkdir {final_dest}: {err or 'failed'}")
                return errors
        # Detect read-only source (e.g. mounted ISO at /Volumes/) - use cp instead of mv
        is_readonly = src_path.startswith("/Volumes/")
        copy_cmd = ['cp', '-R'] if is_readonly else ['mv']
        if os.path.abspath(src_path) != os.path.abspath(final_dest):
            try:
                items = os.listdir(src_path)
            except OSError as e:
                errors.append(f"Cannot read source {lib_name}: {e}")
                return errors
            if not items:
                errors.append(f"Source library folder {lib_name} is empty (no content to merge)")
                return errors
            for item in items:
                s, d = os.path.join(src_path, item), os.path.join(final_dest, item)
                if os.path.isdir(s):
                    if not os.path.exists(d):
                        code, err = self.run_sudo_cmd(['mkdir', '-p', d], capture_errors=True)
                        if code != 0:
                            errors.append(f"mkdir {d}: {err or 'failed'}")
                            continue
                    for sub in os.listdir(s):
                        target = os.path.join(d, sub)
                        if os.path.exists(target):
                            self.run_sudo_cmd(['rm', '-rf', target])
                        code, err = self.run_sudo_cmd(copy_cmd + [os.path.join(s, sub), target], capture_errors=True)
                        if code != 0:
                            errors.append(f"copy to {target}: {err or 'failed'}")
                else:
                    code, err = self.run_sudo_cmd(copy_cmd + [s, d], capture_errors=True)
                    if code != 0:
                        errors.append(f"copy {item}: {err or 'failed'}")
        # Verify content was actually copied to destination
        try:
            copied_items = os.listdir(final_dest)
            if not copied_items:
                errors.append(f"Destination {final_dest} is empty after copy - no files were created")
        except OSError as e:
            errors.append(f"Cannot verify destination {final_dest}: {e}")
        self.set_permissions(final_dest)
        if register:
            errs = self.create_registration(lib_name.replace(" Library", "").title(), final_dest, xml_path)
            errors.extend(errs)
        return errors
    def create_registration(self, name, final_dest, xml_path=None):
        """Returns list of error strings (empty if OK)."""
        errors = []
        warnings = []
        # Use actual product name with spaces (NI convention)
        plist = f"/Library/Preferences/com.native-instruments.{name}.plist"
        tmp_p = "/tmp/temp.plist"
        try:
            with open(tmp_p, 'wb') as f:
                plistlib.dump({'ContentDir': final_dest, 'ContentVersion': '1.0.0'}, f)
        except Exception as e:
            errors.append(f"Write plist for {name}: {e}")
            return errors
        code, err = self.run_sudo_cmd(['mv', tmp_p, plist], capture_errors=True)
        if code != 0:
            errors.append(f"Install plist for {name}: {err or 'sudo mv failed'}")
        elif not os.path.exists(plist):
            errors.append(f"Plist for {name} not found at {plist} after installation")
        else:
            self.set_permissions(plist)
            warnings.append(f"✓ Created plist: {plist}")
        img_root = "/Users/Shared/NI Resources/image"
        code, err = self.run_sudo_cmd(['mkdir', '-p', img_root], capture_errors=True)
        if code != 0:
            errors.append(f"Create image dir: {err or 'failed'}")
        img_src = os.path.join(final_dest, 'PAResources', 'image', name)
        if os.path.exists(img_src):
            img_dst = os.path.join(img_root, name)
            if os.path.exists(img_dst):
                self.run_sudo_cmd(['rm', '-rf', img_dst])
            code, err = self.run_sudo_cmd(['cp', '-R', img_src, img_dst], capture_errors=True)
            if code != 0:
                errors.append(f"Copy image: {err or 'failed'}")
            else:
                self.set_permissions(img_dst)
        sc = "/Library/Application Support/Native Instruments/Service Center"
        code, err = self.run_sudo_cmd(['mkdir', '-p', sc], capture_errors=True)
        if code != 0:
            errors.append(f"Create Service Center dir: {err or 'failed'}")
        if xml_path and os.path.exists(xml_path):
            xml_dest = os.path.join(sc, f"{name}.xml")
            code, err = self.run_sudo_cmd(['cp', xml_path, xml_dest], capture_errors=True)
            if code != 0:
                errors.append(f"Copy XML for {name}: {err or 'failed'}")
            elif not os.path.exists(xml_dest):
                errors.append(f"XML for {name} not found at {xml_dest} after copy")
            else:
                self.set_permissions(xml_dest)
                warnings.append(f"✓ Copied XML from ISO: {xml_dest}")
        else:
            self.fetch_xml_silent(name)
            # Check if XML was created
            xml_check = os.path.join(sc, f"{name}.xml")
            if os.path.exists(xml_check):
                warnings.append(f"✓ Fetched XML: {xml_check}")
        # Return errors but print warnings to console
        if warnings:
            for w in warnings:
                print(w)
        return errors
    def fetch_xml_silent(self, name):
        try:
            r = requests.get("https://api.native-instruments.com/static/phints", timeout=5)
            if r.status_code == 200:
                t = r.text; pos = t.lower().find(f">{name.lower()}</name>")
                if pos != -1:
                    s, e = t.rfind('<product', 0, pos), t.find('</product>', pos) + 10
                    xml = f'<?xml version="1.0" encoding="UTF-8"?>\n<ProductHints>\n{t[s:e]}\n</ProductHints>'
                    sc = "/Library/Application Support/Native Instruments/Service Center"
                    self.run_sudo_cmd(['mkdir', '-p', sc]); tmp_x = "/tmp/temp.xml"
                    with open(tmp_x, "w") as f: f.write(xml)
                    self.run_sudo_cmd(['mv', tmp_x, os.path.join(sc, f"{name}.xml")])
                    self.set_permissions(os.path.join(sc, f"{name}.xml"))
        except: pass
    def repair_ni_permissions(self):
        if self.preflight_sudo():
            for p in ["/Users/Shared/NI Resources", "/Library/Preferences", "/Library/Application Support/Native Instruments"]:
                if os.path.exists(p): self.set_permissions(p)
            messagebox.showinfo("Done", "Permissions repaired.")
if __name__ == "__main__":
    root = tk.Tk(); app = MaschineMachineApp(root); root.mainloop()