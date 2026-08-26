//
//  OrbitDeck-Bridging-Header.h
//  Exposes the vendored MIT ft8_lib C API (FT4/FT8 encode + decode) to Swift.
//
//  Requires the target's Header Search Paths to include the ft8_lib root:
//    $(SRCROOT)/OrbitDeckIOS/DigitalModes/ft8_lib
//  so the library's own <ft8/...>, <fft/...>, <common/...> includes resolve.
//

#import <ft8/encode.h>
#import <ft8/decode.h>
#import <ft8/message.h>
#import <ft8/constants.h>
#import <common/monitor.h>
