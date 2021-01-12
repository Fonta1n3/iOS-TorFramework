# Tor.framework

Tor.framework is the easiest way to embed Tor in your iOS application. The API is *not* stable yet, and subject to change.

Currently, the framework compiles in static versions of `tor`, `libevent`, `openssl`, and `liblzma`:

|          |         |
|:-------- | -------:|
| tor      | 0.4.4.6 |
| libevent | 2.1.11  |
| OpenSSL  | 1.1.1h  |
| liblzma  | 5.2.5   |

## Installation

✅ **Note from Blockchain Commons:** This fork of [Tor.framework](https://github.com/iCepa/Tor.framework) includes a shell script that builds a universal XCFramework that supports iOS devices, the iOS Simulator, Mac Catalyst, and MacOS native across both arm64 and x86_64 processor architectures.

You **do not** use Carthage to build this.

These prerequisite tools must be installed:

```bash
brew install automake autoconf libtool gettext
```

Here are the build instructions:

```bash
git clone git@github.com:BlockchainCommons/iOS-TorFramework
cd iOS-TorFramework
./build.sh
```

The built XCFramework will be found in `iOS-TorFramework/build/Tor.xcframework`.

As of this time, this special build does not yet integrate with the testing target in the original XCode project. The script also makes no effort to be efficient about rebuilds and will rebuild almost everything every time it is run. To ensure a completely clean build, run `./clean.sh` first.

---

## Usage

Starting an instance of Tor involves using three classes: `TORThread`, `TORConfiguration` and `TORController`.

Here is an example of integrating Tor with `NSURLSession`:

```objc
TORConfiguration *configuration = [TORConfiguration new];
configuration.cookieAuthentication = @(YES);
configuration.dataDirectory = [NSURL URLWithString:NSTemporaryDirectory()];
configuration.controlSocket = [configuration.dataDirectory URLByAppendingPathComponent:@"control_port"];
configuration.arguments = @[@"--ignore-missing-torrc"];

TORThread *thread = [[TORThread alloc] initWithConfiguration:configuration];
[thread start];

NSURL *cookieURL = [configuration.dataDirectory URLByAppendingPathComponent:@"control_auth_cookie"];
NSData *cookie = [NSData dataWithContentsOfURL:cookieURL];
TORController *controller = [[TORController alloc] initWithSocketURL:configuration.controlSocket];
[controller authenticateWithData:cookie completion:^(BOOL success, NSError *error) {
    if (!success)
        return;

    [controller addObserverForCircuitEstablished:^(BOOL established) {
        if (!established)
            return;

        [controller getSessionConfiguration:^(NSURLSessionConfiguration *configuration) {
            NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
            ...
        }];
    }];
}];
```

## License

Tor.framework is available under the MIT license. See the
[`LICENSE`](https://github.com/iCepa/Tor.framework/blob/master/LICENSE) file for more info.
