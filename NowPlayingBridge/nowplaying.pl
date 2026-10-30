#!/usr/bin/perl
# Memuat NowPlayingBridge.dylib ke dalam /usr/bin/perl (binary Apple yang masih
# diizinkan membaca Now Playing sistem) lalu memanggil fungsinya sebagai XSUB.
#
# Pemakaian: nowplaying.pl /path/NowPlayingBridge.dylib stream|get|send [command]
use strict;
use warnings;
use DynaLoader;

my ($lib, $function, $command) = @ARGV;
die "Pemakaian: $0 LIB stream|get|send [command]\n" unless $lib && $function;
die "Fungsi tidak dikenal: $function\n" unless $function =~ /^(stream|get|send)$/;
$ENV{NIP_COMMAND} = $command if defined $command;

my $handle = DynaLoader::dl_load_file($lib, 0) or die "Gagal memuat $lib\n";
my $symbol = DynaLoader::dl_find_symbol($handle, "nip_$function") or die "Simbol nip_$function tidak ada\n";
my $sub = DynaLoader::dl_install_xsub("main::nip_$function", $symbol);
&$sub();
