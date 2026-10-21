<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Hardware Diagnostic Toolkit - README</title>
<script src="./vendor/react.js"></script>
<script src="./vendor/react-dom.js"></script>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&amp;family=Lato:wght@400;700;900&amp;display=swap" rel="stylesheet">
<style>
body{margin:0;background:#E9ECF1}
a{color:#1A54C9}a:hover{color:#0F3A92}
code{font-family:'IBM Plex Mono',monospace;font-size:0.92em;background:#EEF2F8;border:1px solid #D7DDE6;border-radius:4px;padding:1px 6px}
</style>
</helmet>
<div style="font-family: Lato, system-ui, sans-serif; color: #13161B; background: #E9ECF1; padding: 40px 16px 64px; box-sizing: border-box">
<main style="max-width: 1180px; margin: 0 auto; background: #FBFCFD; border: 1.5px solid #13161B; box-sizing: border-box">

<div aria-hidden="true" style="display: flex; border-bottom: 1px solid #13161B; font-family: 'IBM Plex Mono', monospace; font-size: 11px; color: #5B6472">
<div style="flex: 1 1 0; text-align: center; padding: 4px 0; border-right: 1px solid #C9D0DA">1</div>
<div style="flex: 1 1 0; text-align: center; padding: 4px 0; border-right: 1px solid #C9D0DA">2</div>
<div style="flex: 1 1 0; text-align: center; padding: 4px 0; border-right: 1px solid #C9D0DA">3</div>
<div style="flex: 1 1 0; text-align: center; padding: 4px 0; border-right: 1px solid #C9D0DA">4</div>
<div style="flex: 1 1 0; text-align: center; padding: 4px 0; border-right: 1px solid #C9D0DA">5</div>
<div style="flex: 1 1 0; text-align: center; padding: 4px 0; border-right: 1px solid #C9D0DA">6</div>
<div style="flex: 1 1 0; text-align: center; padding: 4px 0; border-right: 1px solid #C9D0DA">7</div>
<div style="flex: 1 1 0; text-align: center; padding: 4px 0">8</div>
</div>

<header style="display: flex; flex-wrap: wrap; border-bottom: 1px solid #13161B">
<div style="flex: 999 1 420px; display: flex; align-items: center; gap: 14px; padding: 18px 28px; border-right: 1px solid #13161B">
<svg aria-hidden="true" width="30" height="30" viewBox="0 0 30 30"><rect x="1" y="1" width="28" height="28" rx="7" fill="{{accent}}"></rect><polyline points="6,16 11,16 13,10 17,21 19,14 24,14" fill="none" stroke="#FFFFFF" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"></polyline></svg>
<div style="font-weight: 900; font-size: 17px; letter-spacing: 0.22em">HARDWARE DIAGNOSTIC TOOLKIT</div>
</div>
<div style="flex: 1 1 360px; display: flex; font-family: 'IBM Plex Mono', monospace">
<div style="flex: 1 1 0; padding: 10px 16px; border-right: 1px solid #C9D0DA"><div style="font-size: 11px; color: #5B6472">REV</div><div style="font-weight: 600; font-size: 15px">1.26.0</div></div>
<div style="flex: 1 1 0; padding: 10px 16px; border-right: 1px solid #C9D0DA"><div style="font-size: 11px; color: #5B6472">KERNEL</div><div style="font-weight: 600; font-size: 15px">Linux 7.0</div></div>
<div style="flex: 1 1 0; padding: 10px 16px"><div style="font-size: 11px; color: #5B6472">BASE</div><div style="font-weight: 600; font-size: 15px">Ubuntu 24.04</div></div>
</div>
</header>

<section style="padding: 56px 28px 48px; border-bottom: 1px solid #13161B; display: flex; flex-wrap: wrap; gap: 40px; align-items: flex-end">
<div style="flex: 999 1 520px">
<div style="font-family: 'IBM Plex Mono', monospace; font-size: 13px; color: #5B6472; letter-spacing: 0.14em">FIG. 1 — A BENCH ON A USB STICK</div>
<h1 style="margin: 14px 0 18px; font-size: 56px; line-height: 1.05; font-weight: 900; letter-spacing: -0.01em">Boot the laptop. Pick a test. Keep the report.</h1>
<p style="margin: 0; max-width: 640px; font-size: 19px; line-height: 1.55; color: #3A414C">A minimal Ubuntu live system that starts straight into a full-screen tile menu of hardware tests, and writes a per-machine report to the USB stick. Built for the laptop repair bench at Data Dynamics, Johor — mostly Dynabook and Toshiba.</p>
<div style="display: flex; flex-wrap: wrap; gap: 12px; margin-top: 30px">
<a href="#quick-start" style="display: inline-flex; align-items: center; min-height: 46px; padding: 0 22px; background: {{accent}}; color: #FFFFFF; text-decoration: none; font-weight: 700; border-radius: 6px">Quick start</a>
<a href="#build" style="display: inline-flex; align-items: center; min-height: 46px; padding: 0 22px; border: 1.5px solid #13161B; color: #13161B; text-decoration: none; font-weight: 700; border-radius: 6px">Build from source</a>
</div>
</div>
<div style="flex: 1 1 300px; display: flex; flex-direction: column; border: 1px solid #13161B; font-family: 'IBM Plex Mono', monospace; font-size: 14px">
<div style="display: flex; justify-content: space-between; gap: 12px; padding: 12px 16px; border-bottom: 1px solid #C9D0DA"><span style="color: #5B6472">TILES ON THE HOME GRID</span><span style="font-weight: 600">19</span></div>
<div style="display: flex; justify-content: space-between; gap: 12px; padding: 12px 16px; border-bottom: 1px solid #C9D0DA"><span style="color: #5B6472">PERIPHERAL TESTS</span><span style="font-weight: 600">13</span></div>
<div style="display: flex; justify-content: space-between; gap: 12px; padding: 12px 16px; border-bottom: 1px solid #C9D0DA"><span style="color: #5B6472">LANGUAGES</span><span style="font-weight: 600">6</span></div>
<div style="display: flex; justify-content: space-between; gap: 12px; padding: 12px 16px"><span style="color: #5B6472">WRITES TO THE DRIVE IT COPIES</span><span style="font-weight: 600">never*</span></div>
</div>
</section>

<section id="quick-start" style="padding: 44px 28px; border-bottom: 1px solid #13161B">
<h2 style="margin: 0 0 6px; font-size: 14px; font-weight: 900; letter-spacing: 0.2em">QUICK START</h2>
<p style="margin: 0 0 26px; color: #5B6472">Four steps from a fresh stick to a saved report.</p>
<div style="display: flex; flex-wrap: wrap; gap: 16px">
<div style="flex: 1 1 240px; border: 1px solid #C9D0DA; background: #FFFFFF; padding: 20px; display: flex; flex-direction: column; gap: 10px">
<div style="display: flex; align-items: center; justify-content: center; width: 34px; height: 34px; border-radius: 50%; border: 1.5px solid #13161B; font-family: 'IBM Plex Mono', monospace; font-weight: 600">1</div>
<div style="font-weight: 700; font-size: 17px">Put it on a stick</div>
<div style="color: #3A414C; line-height: 1.5">Copy <code>hw-diagnostic-toolkit vX.Y.Z.iso</code> onto a Ventoy stick, or write it with Rufus or dd.</div>
</div>
<div style="flex: 1 1 240px; border: 1px solid #C9D0DA; background: #FFFFFF; padding: 20px; display: flex; flex-direction: column; gap: 10px">
<div style="display: flex; align-items: center; justify-content: center; width: 34px; height: 34px; border-radius: 50%; border: 1.5px solid #13161B; font-family: 'IBM Plex Mono', monospace; font-weight: 600">2</div>
<div style="font-weight: 700; font-size: 17px">Secure Boot off</div>
<div style="color: #3A414C; line-height: 1.5">The image is unsigned. Turn Secure Boot off in the laptop's BIOS setup.</div>
</div>
<div style="flex: 1 1 240px; border: 1px solid #C9D0DA; background: #FFFFFF; padding: 20px; display: flex; flex-direction: column; gap: 10px">
<div style="display: flex; align-items: center; justify-content: center; width: 34px; height: 34px; border-radius: 50%; border: 1.5px solid #13161B; font-family: 'IBM Plex Mono', monospace; font-weight: 600">3</div>
<div style="font-weight: 700; font-size: 17px">Boot and choose a language</div>
<div style="color: #3A414C; line-height: 1.5">The Language menu opens first on every boot. Enter goes on to the home grid.</div>
</div>
<div style="flex: 1 1 240px; border: 1px solid #C9D0DA; background: #FFFFFF; padding: 20px; display: flex; flex-direction: column; gap: 10px">
<div style="display: flex; align-items: center; justify-content: center; width: 34px; height: 34px; border-radius: 50%; border: 1.5px solid #13161B; font-family: 'IBM Plex Mono', monospace; font-weight: 600">4</div>
<div style="font-weight: 700; font-size: 17px">Test, then save</div>
<div style="color: #3A414C; line-height: 1.5">Run Full run, or press a test's number. Save report writes the machine's report to the stick.</div>
</div>
</div>
</section>

<section style="padding: 44px 28px; border-bottom: 1px solid #13161B">
<div style="display: flex; flex-wrap: wrap; justify-content: space-between; align-items: baseline; gap: 12px; margin-bottom: 18px">
<h2 style="margin: 0; font-size: 14px; font-weight: 900; letter-spacing: 0.2em">PARTS LIST — THE HOME GRID</h2>
<span style="font-family: 'IBM Plex Mono', monospace; font-size: 12px; color: #5B6472">PRESS THE NUMBER, OR CLICK THE TILE</span>
</div>
<div style="border-top: 1.5px solid #13161B; font-size: 16px">
<div style="display: flex; flex-wrap: wrap; gap: 4px 20px; padding: 12px 4px; border-bottom: 1px solid #DDE2E9; font-family: 'IBM Plex Mono', monospace; font-size: 12px; color: #5B6472"><span style="flex: 0 0 40px">NO.</span><span style="flex: 0 0 180px">ITEM</span><span style="flex: 1 1 300px">WHAT IT DOES</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 4px 20px; padding: 12px 4px; border-bottom: 1px solid #DDE2E9"><span style="flex: 0 0 40px; font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">01</span><span style="flex: 0 0 180px; font-weight: 700">Full run</span><span style="flex: 1 1 300px; color: #3A414C">System info, drivers, GPU, battery and SMART, then the longer drive, CPU and RAM tests, the error log, and the report.</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 4px 20px; padding: 12px 4px; border-bottom: 1px solid #DDE2E9"><span style="flex: 0 0 40px; font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">02</span><span style="flex: 0 0 180px; font-weight: 700">HDD / SSD</span><span style="flex: 1 1 300px; color: #3A414C">SMART, self-test, benchmark, surface scan, controller check, install simulation.</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 4px 20px; padding: 12px 4px; border-bottom: 1px solid #DDE2E9"><span style="flex: 0 0 40px; font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">03</span><span style="flex: 0 0 180px; font-weight: 700">CPU</span><span style="flex: 1 1 300px; color: #3A414C">Every core loaded while temperature, clock and throttling are logged.</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 4px 20px; padding: 12px 4px; border-bottom: 1px solid #DDE2E9"><span style="flex: 0 0 40px; font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">04</span><span style="flex: 0 0 180px; font-weight: 700">RAM</span><span style="flex: 1 1 300px; color: #3A414C">Stress test over the free memory; MemTest86+ is on the boot menu for full coverage.</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 4px 20px; padding: 12px 4px; border-bottom: 1px solid #DDE2E9"><span style="flex: 0 0 40px; font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">05</span><span style="flex: 0 0 180px; font-weight: 700">GPU</span><span style="flex: 1 1 300px; color: #3A414C">Every graphics chip: wakes the discrete one, checks its PCIe lanes and link errors. No GPU driver is loaded.</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 4px 20px; padding: 12px 4px; border-bottom: 1px solid #DDE2E9"><span style="flex: 0 0 40px; font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">06</span><span style="flex: 0 0 180px; font-weight: 700">Battery</span><span style="flex: 1 1 300px; color: #3A414C">Capacity against design, and a drain test whose log is kept on the USB stick.</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 4px 20px; padding: 12px 4px; border-bottom: 1px solid #DDE2E9"><span style="flex: 0 0 40px; font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">07</span><span style="flex: 0 0 180px; font-weight: 700">Keyboard</span><span style="flex: 1 1 300px; color: #3A414C">Every key on the layout lights as it is pressed.</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 4px 20px; padding: 12px 4px; border-bottom: 1px solid #DDE2E9"><span style="flex: 0 0 40px; font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">08</span><span style="flex: 0 0 180px; font-weight: 700">Disk imaging</span><span style="flex: 1 1 300px; color: #3A414C">Clone, back up, restore, check, resize partitions, browse an image.</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 4px 20px; padding: 12px 4px; border-bottom: 1px solid #DDE2E9"><span style="flex: 0 0 40px; font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">09</span><span style="flex: 0 0 180px; font-weight: 700">Peripherals</span><span style="flex: 1 1 300px; color: #3A414C">Thirteen tests behind one tile - listed below.</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 4px 20px; padding: 12px 4px; border-bottom: 1px solid #DDE2E9"><span style="flex: 0 0 40px; font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">10</span><span style="flex: 0 0 180px; font-weight: 700">Show all tests</span><span style="flex: 1 1 300px; color: #3A414C">Every test on one list.</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 4px 20px; padding: 12px 4px; border-bottom: 1px solid #DDE2E9"><span style="flex: 0 0 40px; font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">11</span><span style="flex: 0 0 180px; font-weight: 700">Wi-Fi</span><span style="flex: 1 1 300px; color: #3A414C">Join a network - for firmware downloads and the network tests.</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 4px 20px; padding: 12px 4px; border-bottom: 1px solid #DDE2E9"><span style="flex: 0 0 40px; font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">12</span><span style="flex: 0 0 180px; font-weight: 700">Driver check</span><span style="flex: 1 1 300px; color: #3A414C">What each device's driver actually made; fixes it and fetches missing firmware.</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 4px 20px; padding: 12px 4px; border-bottom: 1px solid #DDE2E9"><span style="flex: 0 0 40px; font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">13</span><span style="flex: 0 0 180px; font-weight: 700">DMI capture</span><span style="flex: 1 1 300px; color: #3A414C">Board and serial details saved for a board swap. Never written to firmware.</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 4px 20px; padding: 12px 4px; border-bottom: 1px solid #DDE2E9"><span style="flex: 0 0 40px; font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">14</span><span style="flex: 0 0 180px; font-weight: 700">Results</span><span style="flex: 1 1 300px; color: #3A414C">The report so far; - and + change the text size.</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 4px 20px; padding: 12px 4px; border-bottom: 1px solid #DDE2E9"><span style="flex: 0 0 40px; font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">15</span><span style="flex: 0 0 180px; font-weight: 700">Save report</span><span style="flex: 1 1 300px; color: #3A414C">Writes the per-machine report to the USB stick.</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 4px 20px; padding: 12px 4px; border-bottom: 1px solid #DDE2E9"><span style="flex: 0 0 40px; font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">16</span><span style="flex: 0 0 180px; font-weight: 700">Command prompt</span><span style="flex: 1 1 300px; color: #3A414C">A shell, for anything the tiles do not cover.</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 4px 20px; padding: 12px 4px; border-bottom: 1px solid #DDE2E9"><span style="flex: 0 0 40px; font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">17</span><span style="flex: 0 0 180px; font-weight: 700">System</span><span style="flex: 1 1 300px; color: #3A414C">Machine, CPU, memory, drives; More info adds the motherboard, MAC addresses and PCIe.</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 4px 20px; padding: 12px 4px; border-bottom: 1px solid #DDE2E9"><span style="flex: 0 0 40px; font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">18</span><span style="flex: 0 0 180px; font-weight: 700">Settings</span><span style="flex: 1 1 300px; color: #3A414C">Theme, menu style, text size, language - kept on the boot stick.</span></div>
<div style="display: flex; flex-wrap: wrap; gap: 4px 20px; padding: 12px 4px; border-bottom: 1.5px solid #13161B"><span style="flex: 0 0 40px; font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">19</span><span style="flex: 0 0 180px; font-weight: 700">Error log</span><span style="flex: 1 1 300px; color: #3A414C">Hardware faults the kernel logged while the tests ran.</span></div>
</div>
<div style="margin-top: 28px; font-family: 'IBM Plex Mono', monospace; font-size: 12px; color: #5B6472; letter-spacing: 0.12em">09 — PERIPHERALS</div>
<div style="display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px">
<span style="border: 1px solid #C9D0DA; background: #FFFFFF; padding: 8px 14px; border-radius: 999px">Screen</span>
<span style="border: 1px solid #C9D0DA; background: #FFFFFF; padding: 8px 14px; border-radius: 999px">Touchpad</span>
<span style="border: 1px solid #C9D0DA; background: #FFFFFF; padding: 8px 14px; border-radius: 999px">Touchscreen</span>
<span style="border: 1px solid #C9D0DA; background: #FFFFFF; padding: 8px 14px; border-radius: 999px">Sound</span>
<span style="border: 1px solid #C9D0DA; background: #FFFFFF; padding: 8px 14px; border-radius: 999px">USB ports</span>
<span style="border: 1px solid #C9D0DA; background: #FFFFFF; padding: 8px 14px; border-radius: 999px">Charging</span>
<span style="border: 1px solid #C9D0DA; background: #FFFFFF; padding: 8px 14px; border-radius: 999px">Camera</span>
<span style="border: 1px solid #C9D0DA; background: #FFFFFF; padding: 8px 14px; border-radius: 999px">Ethernet</span>
<span style="border: 1px solid #C9D0DA; background: #FFFFFF; padding: 8px 14px; border-radius: 999px">Wireless</span>
<span style="border: 1px solid #C9D0DA; background: #FFFFFF; padding: 8px 14px; border-radius: 999px">Driver check</span>
<span style="border: 1px solid #C9D0DA; background: #FFFFFF; padding: 8px 14px; border-radius: 999px">SD card</span>
<span style="border: 1px solid #C9D0DA; background: #FFFFFF; padding: 8px 14px; border-radius: 999px">Lid sensor</span>
<span style="border: 1px solid #C9D0DA; background: #FFFFFF; padding: 8px 14px; border-radius: 999px">Fan</span>
</div>
<p style="margin: 16px 0 0; color: #5B6472; line-height: 1.5">A peripheral test that fails, or finds no device, runs Driver check for that kind of device straight away and offers the test again.</p>
</section>

<section style="padding: 44px 28px; border-bottom: 1px solid #13161B; display: flex; flex-wrap: wrap; gap: 36px">
<div style="flex: 1 1 420px">
<h2 style="margin: 0 0 18px; font-size: 14px; font-weight: 900; letter-spacing: 0.2em">DISK IMAGING</h2>
<div style="display: flex; flex-direction: column; border-top: 1px solid #C9D0DA">
<div style="display: flex; gap: 14px; padding: 12px 0; border-bottom: 1px solid #DDE2E9"><span style="font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">1</span><span><strong>Clone a drive</strong> - old drive to new; disk and partition IDs are kept, so Windows boots.</span></div>
<div style="display: flex; gap: 14px; padding: 12px 0; border-bottom: 1px solid #DDE2E9"><span style="font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">2</span><span><strong>Back up to an image</strong> - a Clonezilla-compatible folder on a USB drive or OneDrive.</span></div>
<div style="display: flex; gap: 14px; padding: 12px 0; border-bottom: 1px solid #DDE2E9"><span style="font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">3</span><span><strong>Restore an image</strong> - toolkit, Clonezilla or Macrium Reflect 7/8 images, sizes adjustable before it runs.</span></div>
<div style="display: flex; gap: 14px; padding: 12px 0; border-bottom: 1px solid #DDE2E9"><span style="font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">4</span><span><strong>Check an image</strong> - reads every block back against its checksum.</span></div>
<div style="display: flex; gap: 14px; padding: 12px 0; border-bottom: 1px solid #DDE2E9"><span style="font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">5</span><span><strong>Partitions</strong> - split C:, resize, move, make new ones by dragging; nothing is written until Apply.</span></div>
<div style="display: flex; gap: 14px; padding: 12px 0; border-bottom: 1px solid #DDE2E9"><span style="font-family: 'IBM Plex Mono', monospace; color: {{accent}}; font-weight: 600">6</span><span><strong>Browse an image</strong> - open a partition inside an image and copy files out.</span></div>
</div>
</div>
<div style="flex: 1 1 340px; display: flex; flex-direction: column; gap: 16px">
<div style="border: 1.5px solid #13161B; background: #FFFFFF; padding: 20px">
<div style="font-family: 'IBM Plex Mono', monospace; font-size: 12px; color: #5B6472; letter-spacing: 0.12em">SAFETY</div>
<p style="margin: 10px 0 0; line-height: 1.55">The drive being copied is set read-only in the kernel for the whole job. A target is written only after you type <code>ERASE</code>.</p>
</div>
<div style="border: 1px solid #C9D0DA; background: #FFFFFF; padding: 20px">
<div style="font-family: 'IBM Plex Mono', monospace; font-size: 12px; color: #5B6472; letter-spacing: 0.12em">LANGUAGES</div>
<p style="margin: 10px 0 0; line-height: 1.7">English · English (UK) · 简体中文 · 繁體中文 · 日本語 · 한국어</p>
<p style="margin: 6px 0 0; color: #5B6472; font-size: 14px; line-height: 1.5">Every screen; the saved report stays in English. Machine-translated, waiting for a native speaker's review.</p>
</div>
</div>
</section>

<section id="build" style="padding: 44px 28px; border-bottom: 1px solid #13161B; display: flex; flex-wrap: wrap; gap: 36px">
<div style="flex: 1 1 440px; min-width: 0">
<h2 style="margin: 0 0 8px; font-size: 14px; font-weight: 900; letter-spacing: 0.2em">BUILD FROM SOURCE</h2>
<p style="margin: 0 0 18px; color: #3A414C; line-height: 1.55">Linux as root with internet: Ubuntu 24.04, a VM, or WSL2 - clone inside the Linux filesystem, never under <code>/mnt/c</code>.</p>
<pre style="margin: 0; background: #13161B; color: #E9EDF3; padding: 20px; border-radius: 6px; overflow-x: auto; font-family: 'IBM Plex Mono', monospace; font-size: 14px; line-height: 1.7">sudo ./setup-host.sh
sudo ./build-all.sh          # from nothing, 20-40 min
sudo ./build-all.sh quick    # after editing toolkit/</pre>
<p style="margin: 14px 0 0; color: #5B6472; font-size: 15px">Output: <code>hw-diagnostic-toolkit.iso</code>, a hybrid image for dd, Rufus or Ventoy.</p>
</div>
<div style="flex: 1 1 380px; min-width: 0">
<h2 style="margin: 0 0 8px; font-size: 14px; font-weight: 900; letter-spacing: 0.2em">TRY IT IN A VM</h2>
<p style="margin: 0 0 18px; color: #3A414C; line-height: 1.55">The QEMU harness boots the ISO, sends keys and takes screenshots.</p>
<pre style="margin: 0; background: #13161B; color: #E9EDF3; padding: 20px; border-radius: 6px; overflow-x: auto; font-family: 'IBM Plex Mono', monospace; font-size: 14px; line-height: 1.7">test/boot-vm.sh
test/k.sh ret        # past the Language menu
test/shot.sh home</pre>
<p style="margin: 14px 0 0; color: #5B6472; font-size: 15px">QEMU has no real radio, touchpad or battery, and cannot show GPU driver faults - a pass there is not a pass on the bench.</p>
</div>
</section>

<section style="padding: 44px 28px; border-bottom: 1px solid #13161B">
<h2 style="margin: 0 0 18px; font-size: 14px; font-weight: 900; letter-spacing: 0.2em">RULES IT NEVER BREAKS</h2>
<div style="display: flex; flex-wrap: wrap; gap: 16px">
<div style="flex: 1 1 320px; display: flex; gap: 14px; padding: 16px; background: #FFFFFF; border: 1px solid #C9D0DA"><span style="font-family: 'IBM Plex Mono', monospace; font-weight: 600; color: {{accent}}">A</span><span style="line-height: 1.5">No GPU drivers in the image - one froze a SATELLITE PRO C40-K at boot.</span></div>
<div style="flex: 1 1 320px; display: flex; gap: 14px; padding: 16px; background: #FFFFFF; border: 1px solid #C9D0DA"><span style="font-family: 'IBM Plex Mono', monospace; font-weight: 600; color: {{accent}}">B</span><span style="line-height: 1.5">Nothing is ever written to firmware, DMI or EEPROM.</span></div>
<div style="flex: 1 1 320px; display: flex; gap: 14px; padding: 16px; background: #FFFFFF; border: 1px solid #C9D0DA"><span style="font-family: 'IBM Plex Mono', monospace; font-weight: 600; color: {{accent}}">C</span><span style="line-height: 1.5">Destructive disk tests need ERASE typed, default to No, and never run in Full run.</span></div>
<div style="flex: 1 1 320px; display: flex; gap: 14px; padding: 16px; background: #FFFFFF; border: 1px solid #C9D0DA"><span style="font-family: 'IBM Plex Mono', monospace; font-weight: 600; color: {{accent}}">D</span><span style="line-height: 1.5">Disk imaging never writes the drive it copies.</span></div>
<div style="flex: 1 1 320px; display: flex; gap: 14px; padding: 16px; background: #FFFFFF; border: 1px solid #C9D0DA"><span style="font-family: 'IBM Plex Mono', monospace; font-weight: 600; color: {{accent}}">E</span><span style="line-height: 1.5">A USB socket counts as tested only if something was plugged in during the test.</span></div>
<div style="flex: 1 1 320px; display: flex; gap: 14px; padding: 16px; background: #FFFFFF; border: 1px solid #C9D0DA"><span style="font-family: 'IBM Plex Mono', monospace; font-weight: 600; color: {{accent}}">F</span><span style="line-height: 1.5">The boot stick stays in - except on the "run from RAM" entry.</span></div>
</div>
<p style="margin: 18px 0 0; color: #5B6472; font-size: 14px">* The only writes to a source drive are two named choices: discarding hibernation, and shrinking C: after typing SHRINK.</p>
</section>

<footer style="padding: 24px 28px; display: flex; flex-wrap: wrap; justify-content: space-between; gap: 12px; font-family: 'IBM Plex Mono', monospace; font-size: 13px; color: #5B6472">
<span>Owner: Ash · Data Dynamics, Johor</span>
<span>History: docs/HISTORY.md · Brief: CLAUDE.md</span>
</footer>
</main>
</div>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{"accent":{"editor":"color","default":"#1A54C9"},"$preview":{"width":1440,"height":3900}}'>
class Component extends DCLogic {
renderVals() {
return { accent: this.props.accent ?? '#1A54C9' };
}
}
</script>
</body>
</html>
