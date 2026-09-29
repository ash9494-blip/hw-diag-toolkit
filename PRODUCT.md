# Product

<!-- impeccable:product-schema 1 -->

## Platform

framebuffer
<!-- Not web, iOS or Android: a Python/Pillow renderer drawing straight to the
Linux framebuffer (/dev/fb0) of a booted live USB. No browser, no GPU
drivers (by design), no compositor. Every frame is a PIL image blitted whole. -->

## Users

Repair-bench technicians at Data Dynamics (Johor), led by Ash (Senior IT
Engineer), testing customer laptops - mostly Dynabook/Toshiba - before and
after repair. Customers sometimes see the screen at the counter or at
handover, so the interface also represents the shop.

## Product Purpose

Boot any laptop from a USB stick straight into a full-screen menu of hardware
tests (disk, CPU, RAM, battery, keyboard, screen, touchpad, sound, USB,
camera, network, Wi-Fi), and write a per-machine report back to the stick.
Success: a technician can judge a machine quickly and hand over a report
that stands up in front of the customer.

## Positioning

Runs on the machine under test itself, from its own firmware framebuffer,
with no install and no dependency on the laptop's disk or OS - so it works on
exactly the machines that are broken.

## Operating Context

A repair bench: the laptop open on the bench, often viewed from arm's length
while standing; panels from 1366x768 to 1920x1080 (sometimes higher); mixed
indoor lighting. Driven by keyboard (numbers, arrows, Enter, Q) and, from
1.13, mouse/touchpad/touchscreen. Tests run from minutes to a day.

## Capabilities and Constraints

- Rendering is Pillow onto the framebuffer; full-frame redraws on old
  hardware must stay fast. No GPU effects, no compositing, no animation
  budget worth spending.
- Fonts available in the image: Carlito (regular, bold) and DejaVu Sans Mono;
  any new face must be shipped in the image and asserted at build time.
- Light, dark and high-contrast themes and a 100-200 % text-size setting
  already exist and must keep working.
- Home screen is a numbered tile grid with digit shortcuts; menus are
  numbered lists.
- Redesign scope confirmed by Ash: home grid and menus (navigation) first;
  test screens keep the current look for now.

## Brand Commitments

- Name: "Hardware Diagnostic Toolkit". Ash's 24x24 stroke icon set
  (toolkit/icons) is the tile iconography.
- Must stay readable at arm's length.
- Must not become hard to read, slower, or toy-like; it must look at least as
  professional as today in front of a customer.
- Direction requested by Ash: "cool, sleek, or futuristic", shown as a
  design proposal before anything goes into the build.

## Evidence on Hand

Real screens rendered from toolkit/ui.py; photos of the toolkit running on a
TECRA A40-J. No customer testimonials or metrics - none to be invented.

## Product Principles

1. The machine under test is the hero; the interface is a calm instrument around it.
2. Legible first: every style decision survives arm's length and a dim panel.
3. Instant on any hardware: nothing that costs frame time on an old laptop.
4. Trustworthy in front of a customer: verdicts are unambiguous and look deliberate.
