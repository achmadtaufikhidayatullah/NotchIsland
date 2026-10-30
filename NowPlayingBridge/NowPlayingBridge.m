// Jembatan "Now Playing" sistem untuk NotchIsland.
//
// Sejak macOS 15.4 framework privat MediaRemote hanya melayani proses Apple.
// /usr/bin/perl adalah binary Apple, jadi library ini dimuat ke dalam perl
// (lihat nowplaying.pl) dan mencetak status pemutar sebagai JSON per baris.
// Pola dari ungive/mediaremote-adapter (BSD-3), ditulis ulang seminimal mungkin.
//
// Fungsi diekspor sebagai XSUB perl: argumen (pTHX_ CV*) diabaikan, parameter lewat env.

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendFn)(int, CFDictionaryRef);

static GetInfoFn getInfo;
static GetPlayingFn getPlaying;
static GetPIDFn getPID;
static RegisterFn registerNotifications;
static SendFn sendCommand;

static BOOL loadMediaRemote(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!h) return NO;
    getInfo = (GetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    getPlaying = (GetPlayingFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getPID = (GetPIDFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
    registerNotifications = (RegisterFn)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    sendCommand = (SendFn)dlsym(h, "MRMediaRemoteSendCommand");
    return getInfo && getPlaying && getPID && registerNotifications && sendCommand;
}

static NSString *lastArtworkHash;

/// Satu snapshot → satu baris JSON di stdout. Artwork hanya dikirim saat berubah.
static void emitSnapshot(dispatch_queue_t queue) {
    getInfo(queue, ^(CFDictionaryRef raw) {
        NSDictionary *info = (__bridge NSDictionary *)raw;
        getPlaying(queue, ^(Boolean playing) {
            getPID(queue, ^(int pid) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
                if (title.length == 0) {
                    out[@"empty"] = @YES;
                } else {
                    out[@"title"] = title;
                    out[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
                    out[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
                    out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
                    out[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] ?: @0;
                    out[@"rate"] = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?: @0;
                    NSDate *ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                    if ([ts isKindOfClass:[NSDate class]]) out[@"timestamp"] = @(ts.timeIntervalSince1970);
                    out[@"playing"] = @(playing);
                    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
                    if (app.bundleIdentifier) out[@"bundleID"] = app.bundleIdentifier;
                    if (app.localizedName) out[@"appName"] = app.localizedName;

                    NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                    NSString *hash = art ? [NSString stringWithFormat:@"%lu-%lu", (unsigned long)art.length, (unsigned long)art.hash] : @"";
                    if (![hash isEqualToString:lastArtworkHash ?: @"-"]) {
                        lastArtworkHash = hash;
                        out[@"artwork"] = art ? [art base64EncodedStringWithOptions:0] : @"";
                    }
                }
                NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
                if (json) {
                    fwrite(json.bytes, 1, json.length, stdout);
                    fputc('\n', stdout);
                    fflush(stdout);
                }
            });
        });
    });
}

/// Streaming: snapshot awal, lalu setiap ada perubahan dari sistem. Tidak pernah kembali.
void nip_stream(void *a, void *b) {
    if (!loadMediaRemote()) { fprintf(stderr, "MediaRemote tidak tersedia\n"); exit(2); }
    dispatch_queue_t queue = dispatch_queue_create("notchisland.nowplaying", DISPATCH_QUEUE_SERIAL);
    registerNotifications(queue);
    NSArray *names = @[ @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                        @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                        @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification" ];
    for (NSString *name in names) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
                                                      usingBlock:^(NSNotification *n) { emitSnapshot(queue); }];
    }
    emitSnapshot(queue);
    // Pengaman: snapshot berkala bila ada notifikasi yang terlewat.
    [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *t) {
        if (getppid() == 1) exit(0);   // NotchIsland sudah tertutup → jangan jadi proses yatim
        emitSnapshot(queue);
    }];
    CFRunLoopRun();
}

/// Satu snapshot lalu keluar — dipakai untuk tes kelayakan.
void nip_get(void *a, void *b) {
    if (!loadMediaRemote()) { fprintf(stderr, "MediaRemote tidak tersedia\n"); exit(2); }
    dispatch_queue_t queue = dispatch_queue_create("notchisland.nowplaying", DISPATCH_QUEUE_SERIAL);
    emitSnapshot(queue);
    [NSThread sleepForTimeInterval:1.0];
    exit(0);
}

/// Perintah ke pemutar aktif. NIP_COMMAND: 2 = play/pause, 4 = berikutnya, 5 = sebelumnya.
void nip_send(void *a, void *b) {
    if (!loadMediaRemote()) exit(2);
    const char *cmd = getenv("NIP_COMMAND");
    exit(cmd && sendCommand(atoi(cmd), NULL) ? 0 : 1);
}
