#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LanBridge Windows 端主程序 (可打包为独立 .exe)
支持：Windows <-> Android 互通、双安卓互通、双电脑互通
功能：
1. 局域网 UDP 广播自动发现安卓设备与其他电脑（零配置直连）
2. 双端高速文件互传（电脑 <-> 手机，支持进度展示与一键打开目录）
3. 双向实时投屏（电脑画面投送到手机 / 手机画面投送到电脑）
4. 双向远程操控（统一支持 TAP / DOUBLE_TAP / RIGHT_CLICK / MOVE / SWIPE / KEY 协议）

打包 EXE 命令：
pip install pillow mss pyautogui pyinstaller
pyinstaller -F -w --name LanBridge_Win lanbridge_windows.py
"""

import io
import json
import os
import random
import socket
import struct
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from PIL import Image, ImageTk

# 可选依赖：屏幕抓取与键鼠反控
try:
    import mss
    HAS_MSS = True
except ImportError:
    HAS_MSS = False

try:
    import pyautogui
    pyautogui.FAILSAFE = False
    HAS_PYAUTOGUI = True
except ImportError:
    HAS_PYAUTOGUI = False


# ===================== 网络端口与协议配置 =====================
UDP_DISCOVERY_PORT = 50001   # 局域网设备自动发现端口
FILE_TRANSFER_PORT = 50002   # 双端文件传输 TCP 端口
SCREEN_STREAM_PORT = 50003   # 双向投屏视频流 TCP 端口
CONTROL_EVENT_PORT = 50004   # 双向触控/键鼠反控 TCP 端口

SAVE_DIR = os.path.join(os.path.expanduser("~"), "Desktop", "LanBridge_Received")
os.makedirs(SAVE_DIR, exist_ok=True)


def get_local_ip() -> str:
    """获取本机局域网 IP 地址"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = "127.0.0.1"
    finally:
        s.close()
    return ip


class LanBridgeApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("LanBridge 局域网跨端互传与双向投屏")
        self.root.geometry("980x640")
        self.root.minsize(900, 580)
        self.root.configure(bg="#F8FAFC")

        self.local_ip = get_local_ip()
        self.device_id = f"WIN-{random.randint(1000, 9999)}"
        self.device_name = socket.gethostname()
        self.peer_ip = tk.StringVar(value="")
        self.status_text = tk.StringVar(value=f"就绪 | 本机 IP: {self.local_ip}（等待设备连接或选择列表）")
        self.transfer_progress = tk.DoubleVar(value=0.0)

        self.running = True
        self.streaming_to_phone = False
        self.control_sock = None

        # 远程画面尺寸记录（用于归一化鼠标坐标）
        self.canvas_img_w = 1
        self.canvas_img_h = 1
        self.drag_start = None

        self._build_ui()
        self._start_background_services()

    # ===================== 极简直观 UI 布局 =====================
    def _build_ui(self):
        style = ttk.Style()
        style.theme_use("clam")
        style.configure("Card.TFrame", background="#FFFFFF", relief="flat")
        style.configure("Primary.TButton", font=("Microsoft YaHei UI", 10, "bold"), padding=8)
        style.configure("Action.TButton", font=("Microsoft YaHei UI", 10), padding=6)

        # 顶部状态栏
        header = tk.Frame(self.root, bg="#1E293B", height=54)
        header.pack(fill=tk.X)
        tk.Label(
            header,
            text="LanBridge · 局域网极简互传 & 双向投屏反控",
            fg="#FFFFFF",
            bg="#1E293B",
            font=("Microsoft YaHei UI", 13, "bold"),
            padx=18,
            pady=12,
        ).pack(side=tk.LEFT)
        tk.Label(
            header,
            textvariable=self.status_text,
            fg="#94A3B8",
            bg="#1E293B",
            font=("Microsoft YaHei UI", 10),
            padx=18,
        ).pack(side=tk.RIGHT)

        # 主体左右分栏：左侧操作卡片，右侧实时投屏互动画面
        main_pane = tk.Frame(self.root, bg="#F8FAFC", padx=16, pady=16)
        main_pane.pack(fill=tk.BOTH, expand=True)

        left_col = tk.Frame(main_pane, bg="#F8FAFC", width=340)
        left_col.pack(side=tk.LEFT, fill=tk.Y, padx=(0, 14))
        left_col.pack_propagate(False)

        right_col = tk.Frame(main_pane, bg="#0F172A", bd=0)
        right_col.pack(side=tk.RIGHT, fill=tk.BOTH, expand=True)

        # --- 卡片 1：设备连接 ---
        card_conn = tk.LabelFrame(
            left_col,
            text=" 1. 连接局域网设备 ",
            bg="#FFFFFF",
            fg="#0F172A",
            font=("Microsoft YaHei UI", 10, "bold"),
            padx=12,
            pady=10,
        )
        card_conn.pack(fill=tk.X, pady=(0, 12))

        tk.Label(card_conn, text="自动发现的局域网设备（手机/电脑）：", bg="#FFFFFF", fg="#475569").pack(anchor="w")
        self.device_listbox = tk.Listbox(card_conn, height=3, font=("Consolas", 10), relief="solid", bd=1)
        self.device_listbox.pack(fill=tk.X, pady=6)
        self.device_listbox.bind("<<ListboxSelect>>", self._on_select_device)

        ip_row = tk.Frame(card_conn, bg="#FFFFFF")
        ip_row.pack(fill=tk.X, pady=4)
        tk.Label(ip_row, text="对方 IP:", bg="#FFFFFF", fg="#475569").pack(side=tk.LEFT)
        ttk.Entry(ip_row, textvariable=self.peer_ip, width=18).pack(side=tk.LEFT, padx=6, fill=tk.X, expand=True)
        ttk.Button(ip_row, text="连接", command=self._connect_control_channel, style="Action.TButton").pack(side=tk.RIGHT)

        # --- 卡片 2：双向文件互传 ---
        card_file = tk.LabelFrame(
            left_col,
            text=" 2. 双向文件秒传 ",
            bg="#FFFFFF",
            fg="#0F172A",
            font=("Microsoft YaHei UI", 10, "bold"),
            padx=12,
            pady=10,
        )
        card_file.pack(fill=tk.X, pady=(0, 12))

        ttk.Button(
            card_file,
            text="📤 选择电脑文件发送到对方设备",
            command=self._choose_and_send_file,
            style="Primary.TButton",
        ).pack(fill=tk.X, pady=(2, 8))

        ttk.Progressbar(card_file, variable=self.transfer_progress, maximum=100).pack(fill=tk.X, pady=4)

        ttk.Button(
            card_file,
            text="📂 打开接收到的文件目录",
            command=lambda: os.startfile(SAVE_DIR) if os.name == "nt" else None,
            style="Action.TButton",
        ).pack(fill=tk.X, pady=(4, 2))

        # --- 卡片 3：双向投屏与互相操控 ---
        card_screen = tk.LabelFrame(
            left_col,
            text=" 3. 双向投屏 & 互相操控 ",
            bg="#FFFFFF",
            fg="#0F172A",
            font=("Microsoft YaHei UI", 10, "bold"),
            padx=12,
            pady=10,
        )
        card_screen.pack(fill=tk.BOTH, expand=True)

        self.btn_cast_pc = ttk.Button(
            card_screen,
            text="🖥️ 将电脑屏幕投屏到手机（允许手机控电脑）",
            command=self._toggle_cast_pc_to_phone,
            style="Primary.TButton",
        )
        self.btn_cast_pc.pack(fill=tk.X, pady=6)

        tk.Label(
            card_screen,
            text="说明：手机发起投屏后，右侧自动显示手机画面。\n• 左键点击 = 手机轻触\n• 左键拖拽 = 手机滑动\n• 右键点击 = 手机返回键\n• 中键点击 = 手机回桌面",
            bg="#FFFFFF",
            fg="#64748B",
            justify=tk.LEFT,
            font=("Microsoft YaHei UI", 9),
        ).pack(anchor="w", pady=6)

        nav_row = tk.Frame(card_screen, bg="#FFFFFF")
        nav_row.pack(fill=tk.X, pady=(4, 0))
        ttk.Button(nav_row, text="◀ 返回", command=lambda: self._send_nav_key("BACK"), style="Action.TButton").pack(
            side=tk.LEFT, expand=True, fill=tk.X, padx=2
        )
        ttk.Button(nav_row, text="● 桌面", command=lambda: self._send_nav_key("HOME"), style="Action.TButton").pack(
            side=tk.LEFT, expand=True, fill=tk.X, padx=2
        )
        ttk.Button(nav_row, text="■ 多任务", command=lambda: self._send_nav_key("RECENTS"), style="Action.TButton").pack(
            side=tk.LEFT, expand=True, fill=tk.X, padx=2
        )

        # --- 右侧：投屏显示与鼠标反控画布 ---
        self.screen_canvas = tk.Canvas(right_col, bg="#0F172A", highlightthickness=0, cursor="hand2")
        self.screen_canvas.pack(fill=tk.BOTH, expand=True)
        self.canvas_hint = self.screen_canvas.create_text(
            300,
            260,
            text="📱 投屏显示区\n\n当手机开启「投屏」时，画面将实时显示在此处\n直接用鼠标点击或拖拽画面即可反向控制手机",
            fill="#64748B",
            font=("Microsoft YaHei UI", 12),
            justify=tk.CENTER,
        )

        # 绑定鼠标事件用于反向控制手机
        self.screen_canvas.bind("<ButtonPress-1>", self._on_canvas_mouse_down)
        self.screen_canvas.bind("<ButtonRelease-1>", self._on_canvas_mouse_up)
        self.screen_canvas.bind("<Double-Button-1>", self._on_canvas_double_click)
        self.screen_canvas.bind("<Button-3>", lambda e: self._send_nav_key("BACK"))
        self.screen_canvas.bind("<Button-2>", lambda e: self._send_nav_key("HOME"))

    # ===================== 1. 局域网 UDP 广播与自动发现 =====================
    def _start_background_services(self):
        threading.Thread(target=self._udp_broadcaster, daemon=True).start()
        threading.Thread(target=self._udp_listener, daemon=True).start()
        threading.Thread(target=self._file_receive_server, daemon=True).start()
        threading.Thread(target=self._screen_receive_server, daemon=True).start()
        threading.Thread(target=self._control_receive_server, daemon=True).start()

    def _udp_broadcaster(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        payload = json.dumps({
            "type": "WINDOWS_PC",
            "id": self.device_id,
            "name": self.device_name,
            "ip": self.local_ip,
        }).encode("utf-8")
        while self.running:
            try:
                sock.sendto(payload, ("<broadcast>", UDP_DISCOVERY_PORT))
            except Exception:
                pass
            time.sleep(2.5)

    def _udp_listener(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("", UDP_DISCOVERY_PORT))
        discovered = set()
        while self.running:
            try:
                data, addr = sock.recvfrom(1024)
                info = json.loads(data.decode("utf-8"))
                peer_id = info.get("id", "")
                ip = info.get("ip") or addr[0]
                if peer_id == self.device_id or ip == self.local_ip:
                    continue
                if info.get("type") in ("ANDROID_PHONE", "WINDOWS_PC"):
                    name = info.get("name", "Device")
                    entry = f"{name} ({ip})"
                    if entry not in discovered:
                        discovered.add(entry)
                        self.root.after(0, lambda e=entry, i=ip: self._add_discovered_device(e, i))
            except Exception:
                pass

    def _add_discovered_device(self, entry: str, ip: str):
        self.device_listbox.insert(tk.END, entry)
        if not self.peer_ip.get():
            self.peer_ip.set(ip)
            self.status_text.set(f"已自动发现设备: {entry}")

    def _on_select_device(self, _event):
        sel = self.device_listbox.curselection()
        if sel:
            text = self.device_listbox.get(sel[0])
            ip = text.split("(")[-1].rstrip(")")
            self.peer_ip.set(ip)

    # ===================== 2. 双端高速文件互传 =====================
    def _choose_and_send_file(self):
        target_ip = self.peer_ip.get().strip()
        if not target_ip:
            messagebox.showwarning("提示", "请先选择或输入对方设备局域网 IP 地址！")
            return
        filepath = filedialog.askopenfilename(title="选择要发送的文件")
        if not filepath:
            return
        threading.Thread(target=self._send_file_worker, args=(target_ip, filepath), daemon=True).start()

    def _send_file_worker(self, target_ip: str, filepath: str):
        filename = os.path.basename(filepath)
        filesize = os.path.getsize(filepath)
        try:
            self.status_text.set(f"正在发送: {filename} ...")
            with socket.create_connection((target_ip, FILE_TRANSFER_PORT), timeout=5) as sock:
                header = json.dumps({"filename": filename, "size": filesize}).encode("utf-8")
                sock.sendall(struct.pack("!I", len(header)) + header)
                sent = 0
                with open(filepath, "rb") as f:
                    while chunk := f.read(65536):
                        sock.sendall(chunk)
                        sent += len(chunk)
                        self.transfer_progress.set((sent / max(1, filesize)) * 100)
            self.status_text.set(f"发送完成: {filename}")
        except Exception as e:
            self.status_text.set(f"发送失败: {e}")

    def _file_receive_server(self):
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("0.0.0.0", FILE_TRANSFER_PORT))
        server.listen(5)
        while self.running:
            try:
                conn, addr = server.accept()
                threading.Thread(target=self._handle_incoming_file, args=(conn, addr), daemon=True).start()
            except Exception:
                pass

    def _handle_incoming_file(self, conn: socket.socket, addr):
        try:
            raw_len = self._recv_exact(conn, 4)
            if not raw_len:
                return
            header_len = struct.unpack("!I", raw_len)[0]
            header = json.loads(self._recv_exact(conn, header_len).decode("utf-8"))
            filename = os.path.basename(header["filename"])
            filesize = int(header["size"])

            save_path = os.path.join(SAVE_DIR, filename)
            received = 0
            self.status_text.set(f"正在接收文件: {filename} ...")
            with open(save_path, "wb") as f:
                while received < filesize:
                    chunk = conn.recv(min(65536, filesize - received))
                    if not chunk:
                        break
                    f.write(chunk)
                    received += len(chunk)
                    self.transfer_progress.set((received / max(1, filesize)) * 100)
            self.status_text.set(f"已收到文件并存入桌面 LanBridge_Received: {filename}")
        except Exception as e:
            self.status_text.set(f"文件接收异常: {e}")
        finally:
            conn.close()

    # ===================== 3. 双向实时投屏 =====================
    def _toggle_cast_pc_to_phone(self):
        if self.streaming_to_phone:
            self.streaming_to_phone = False
            self.btn_cast_pc.configure(text="🖥️ 将电脑屏幕投屏到手机（允许手机控电脑）")
            self.status_text.set("已停止向手机投屏")
            return

        target_ip = self.peer_ip.get().strip()
        if not target_ip:
            messagebox.showwarning("提示", "请先选择或输入手机 IP！")
            return
        if not HAS_MSS:
            messagebox.showerror("缺少依赖", "请先安装 mss 库：pip install mss pillow")
            return

        self.streaming_to_phone = True
        self.btn_cast_pc.configure(text="⏹️ 停止向手机投屏")
        threading.Thread(target=self._stream_pc_screen_worker, args=(target_ip,), daemon=True).start()

    def _stream_pc_screen_worker(self, target_ip: str):
        try:
            with socket.create_connection((target_ip, SCREEN_STREAM_PORT), timeout=5) as sock:
                self.status_text.set(f"正在向设备 ({target_ip}) 实时投屏...")
                with mss.mss() as sct:
                    monitor = sct.monitors[1]
                    while self.streaming_to_phone and self.running:
                        raw = sct.grab(monitor)
                        img = Image.frombytes("RGB", raw.size, raw.bgra, "raw", "BGRX")
                        img.thumbnail((1280, 720))
                        buf = io.BytesIO()
                        img.save(buf, format="JPEG", quality=68)
                        frame_bytes = buf.getvalue()
                        sock.sendall(struct.pack("!I", len(frame_bytes)) + frame_bytes)
                        time.sleep(0.04)  # ~25 FPS
        except Exception as e:
            self.status_text.set(f"电脑投屏中断: {e}")
        finally:
            self.streaming_to_phone = False
            self.root.after(0, lambda: self.btn_cast_pc.configure(text="🖥️ 将电脑屏幕投屏到手机（允许手机控电脑）"))

    def _screen_receive_server(self):
        """接收手机发来的投屏帧并实时渲染在右侧画布"""
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("0.0.0.0", SCREEN_STREAM_PORT))
        server.listen(2)
        while self.running:
            try:
                conn, addr = server.accept()
                if not self.peer_ip.get():
                    self.peer_ip.set(addr[0])
                threading.Thread(target=self._handle_phone_screen_stream, args=(conn, addr[0]), daemon=True).start()
            except Exception:
                pass

    def _handle_phone_screen_stream(self, conn: socket.socket, phone_ip: str):
        self.status_text.set(f"正在显示 ({phone_ip}) 投屏画面（可直接用鼠标反控）")
        try:
            while self.running:
                raw_len = self._recv_exact(conn, 4)
                if not raw_len:
                    break
                frame_len = struct.unpack("!I", raw_len)[0]
                frame_data = self._recv_exact(conn, frame_len)
                if not frame_data:
                    break
                img = Image.open(io.BytesIO(frame_data))
                self.root.after(0, self._update_canvas_frame, img)
        except Exception:
            pass
        finally:
            conn.close()
            self.status_text.set("投屏已结束")

    def _update_canvas_frame(self, img: Image.Image):
        cw = max(100, self.screen_canvas.winfo_width())
        ch = max(100, self.screen_canvas.winfo_height())
        img.thumbnail((cw, ch))
        self.canvas_img_w, self.canvas_img_h = img.size
        self.tk_frame = ImageTk.PhotoImage(img)
        self.screen_canvas.delete("all")
        self.screen_canvas.create_image(cw // 2, ch // 2, image=self.tk_frame, anchor=tk.CENTER)

    # ===================== 4. 双向远程操控（电脑<->手机） =====================
    def _connect_control_channel(self):
        target_ip = self.peer_ip.get().strip()
        if not target_ip:
            return
        try:
            if self.control_sock:
                self.control_sock.close()
            self.control_sock = socket.create_connection((target_ip, CONTROL_EVENT_PORT), timeout=3)
            self.status_text.set(f"已连接远程反控通道 ({target_ip})")
        except Exception as e:
            self.status_text.set(f"连接远程反控通道失败: {e}")

    def _send_control_cmd(self, payload: dict):
        if not self.control_sock:
            self._connect_control_channel()
        if not self.control_sock:
            return
        try:
            data = (json.dumps(payload) + "\n").encode("utf-8")
            self.control_sock.sendall(data)
        except Exception:
            self.control_sock = None

    def _canvas_to_normalized(self, event):
        cw = self.screen_canvas.winfo_width()
        ch = self.screen_canvas.winfo_height()
        offset_x = (cw - self.canvas_img_w) / 2
        offset_y = (ch - self.canvas_img_h) / 2
        nx = min(1.0, max(0.0, (event.x - offset_x) / max(1, self.canvas_img_w)))
        ny = min(1.0, max(0.0, (event.y - offset_y) / max(1, self.canvas_img_h)))
        return round(nx, 4), round(ny, 4)

    def _on_canvas_mouse_down(self, event):
        self.drag_start = self._canvas_to_normalized(event)

    def _on_canvas_mouse_up(self, event):
        if not self.drag_start:
            return
        x1, y1 = self.drag_start
        x2, y2 = self._canvas_to_normalized(event)
        if abs(x2 - x1) < 0.015 and abs(y2 - y1) < 0.015:
            self._send_control_cmd({"cmd": "TAP", "x": x2, "y": y2})
        else:
            self._send_control_cmd({"cmd": "SWIPE", "x1": x1, "y1": y1, "x2": x2, "y2": y2, "duration": 260})
        self.drag_start = None

    def _on_canvas_double_click(self, event):
        x, y = self._canvas_to_normalized(event)
        self._send_control_cmd({"cmd": "DOUBLE_TAP", "x": x, "y": y})

    def _send_nav_key(self, key_name: str):
        self._send_control_cmd({"cmd": "KEY", "key": key_name})

    def _control_receive_server(self):
        """接收手机发来的触控指令并操作 Windows 鼠标键盘"""
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("0.0.0.0", CONTROL_EVENT_PORT))
        server.listen(5)
        while self.running:
            try:
                conn, _ = server.accept()
                threading.Thread(target=self._handle_incoming_control, args=(conn,), daemon=True).start()
            except Exception:
                pass

    def _handle_incoming_control(self, conn: socket.socket):
        if not HAS_PYAUTOGUI:
            conn.close()
            return
        sw, sh = pyautogui.size()
        buf = ""
        try:
            while self.running:
                chunk = conn.recv(1024)
                if not chunk:
                    break
                buf += chunk.decode("utf-8", errors="ignore")
                while "\n" in buf:
                    line, buf = buf.split("\n", 1)
                    if not line.strip():
                        continue
                    msg = json.loads(line)
                    cmd = msg.get("cmd")
                    if cmd == "TAP":
                        pyautogui.click(int(msg["x"] * sw), int(msg["y"] * sh))
                    elif cmd == "DOUBLE_TAP":
                        pyautogui.doubleClick(int(msg["x"] * sw), int(msg["y"] * sh))
                    elif cmd == "RIGHT_CLICK":
                        pyautogui.rightClick(int(msg["x"] * sw), int(msg["y"] * sh))
                    elif cmd == "MOVE":
                        pyautogui.moveTo(int(msg["x"] * sw), int(msg["y"] * sh))
                    elif cmd == "SWIPE":
                        x1, y1 = int(msg["x1"] * sw), int(msg["y1"] * sh)
                        x2, y2 = int(msg["x2"] * sw), int(msg["y2"] * sh)
                        pyautogui.moveTo(x1, y1)
                        pyautogui.dragTo(x2, y2, duration=0.2, button="left")
                    elif cmd == "KEY":
                        key = msg.get("key", "")
                        if key == "BACK":
                            pyautogui.hotkey("alt", "left")
                        elif key == "HOME":
                            pyautogui.hotkey("win", "d")
                        elif key == "RECENTS":
                            pyautogui.hotkey("win", "tab")
                    elif cmd == "SCROLL":
                        pyautogui.scroll(int(msg.get("dy", 0)))
                    elif cmd == "TEXT":
                        pyautogui.write(msg.get("text", ""))
        except Exception:
            pass
        finally:
            conn.close()

    @staticmethod
    def _recv_exact(sock: socket.socket, n: int) -> bytes:
        data = bytearray()
        while len(data) < n:
            packet = sock.recv(n - len(data))
            if not packet:
                return b""
            data.extend(packet)
        return bytes(data)


if __name__ == "__main__":
    root = tk.Tk()
    app = LanBridgeApp(root)
    root.mainloop()