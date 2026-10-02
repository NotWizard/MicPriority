<!-- impeccable:product-schema 1 -->

## Platform

Native macOS, macOS 13 or later, Apple Silicon only.

## Stack

Swift, SwiftUI MenuBarExtra, Core Audio, ServiceManagement, Swift Package Manager, AppKit, IOUSBHost and IOBluetooth. The user authorized implementing the previously delivered native design.

## Users

A Mac user with several input devices who wants a persistent priority order and automatic fallback when an input disappears or becomes unavailable.

## Product Purpose

Select the highest-priority available system input and keep disconnected devices in their saved positions. Ordinary interactions stay in one menu bar panel, without a dashboard or primary window.

## Capabilities and Constraints

Ordered device membership, automatic fallback, stable recovery, temporary selection, pause, persisted preferences, and optional login launch, and user-initiated GitHub release updates. First launch is read-only until the user adds devices and enables management. The tool manages system default input; per-app fixed routes remain a limitation. DJI v2 receiver status and the MiRemoteV Xiaomi Bluetooth source have dedicated availability checks.

## Product Principles

- Use device UIDs as identity and distinguish priority from actual system input.
- Confirm asynchronous writes before reporting success.
- Use event-driven monitoring and bounded retries.
- Never interpret silence or deliberate mute as disconnection.

## Accessibility & Inclusion

Chinese UI, system light/dark appearance, keyboard controls, VoiceOver labels, and up/down menu actions alongside native gap drag ordering. Clicking the highest available priority ends a temporary override.
