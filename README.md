# KratonSecure

A high-performance VPN library for iOS and macOS applications, providing secure network tunneling capabilities.

## Overview

KratonSecure is a Swift library that enables developers to integrate advanced VPN functionality into their iOS and macOS applications. It provides a clean, modern API for establishing secure network connections.

## Features

- High-performance network tunneling
- iOS and macOS support
- Swift Package Manager integration
- Modern Swift API design
- Secure encryption protocols

## Installation

### Swift Package Manager

Add KratonSecure to your project using Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/jhwan2/wireguard-apple.git", from: "1.0.0")
]
```

## Usage

### Basic Integration

1. Import the framework:
```swift
import KratonSecureKit
```

2. Configure your network extension target to include KratonSecure dependencies.

3. Implement the tunnel provider in your network extension.

## Requirements

- iOS 15.0+ / macOS 12.0+
- Xcode 14.0+
- Swift 5.7+

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
