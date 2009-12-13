#!/usr/bin/perl
use warnings;
use strict;

use FindBin;
use Getopt::Long;
use List::Util qw(first);
use YAML;

use POE qw(
    Session
    Component::IRC
    Component::IKC::Server
    Component::IKC::Specifier
);

sub msg (@) { print "[msg] ", "@_\n" }
sub err (@) { print "[err] ", "@_\n" }

my $path = "$FindBin::Bin/../config.yaml";
GetOptions("--config=s", \$path);

msg "loading configuration $path";

my $config_yaml = YAML::LoadFile($path);
my $plugin = first { $_->{module} eq 'Publish::IRC' } @{ $config_yaml->{plugins} }
    or die "Can't find Publish::IRC config in $path";

my $config = $plugin->{config};

msg 'creating daemon component';
POE::Component::IKC::Server->spawn(
    port => $config->{daemon_port} || 9999,
    name => 'NotifyIRCBot',
);

msg 'creating irc component';
POE::Component::IRC->new('bot')
    or die "Couldn't create IRC POE session: $!";

msg 'creating kernel session';
POE::Session->create(
    inline_states => {
        _start           => \&bot_start,
        _stop            => \&bot_stop,
        irc_001          => \&bot_connected,
        irc_372          => \&bot_motd,
        irc_disconnected => \&bot_reconnect,
        irc_error        => \&bot_reconnect,
        irc_socketerr    => \&bot_reconnect,
        autoping         => \&bot_do_autoping,
        update           => \&update,
        _default         => $ENV{DEBUG} ? \&bot_default : sub { },
    }
);

msg 'starting the kernel';
POE::Kernel->run();
msg 'exiting';
exit 0;

sub bot_default
{
    my ( $event, $args ) = @_[ ARG0 .. $#_ ];
    err "unhandled $event";
    err "  - $_" foreach @$args;
    return 0;
}

sub update
{
    my ( $kernel, $heap, $msg ) = @_[ KERNEL, HEAP, ARG0 ];
    eval {
        for my $channel (@{ $config->{server_channels} }) {
            if ($config->{announce} =~ /action/i) {
                $kernel->post( bot => ctcp => $channel, "ACTION $msg");
            } else {
                $kernel->post( bot => notice => $channel, $msg )
            }
        }
    };
    err "update error: $@" if $@;
}

sub bot_start
{
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
    msg "starting irc session";
    $kernel->alias_set('notify_irc');
    $kernel->call( IKC => publish => notify_irc => ['update'] );
    $kernel->post( bot => register => 'all' );
    $kernel->post(
        bot => connect => {
            Nick     => $config->{nickname},
            Ircname  => $config->{ircname} || $config->{nickname},
            Username => $ENV{USER},
            Server   => $config->{server_host},
            Port     => $config->{server_port} || 6667,
        }
    );
}

sub bot_stop
{
    msg "stopping bot";
}

sub bot_connected
{
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
    foreach ( @{$config->{server_channels}} )
    {
        msg "joining channel $_";
        $kernel->post( bot => join => $_ );
        if ($config->{charset}) {
            $kernel->post( bot => charset => $config->{charset} );
        }
    }
}

sub bot_motd
{
    msg '[motd] ' . $_[ARG1];
}

sub bot_do_autoping
{
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
    $kernel->post( bot => userhost => $config->{nickname} )
        unless $heap->{seen_traffic};
    $heap->{seen_traffic} = 0;
    $kernel->delay( autoping => 300 );
}

sub bot_reconnect
{
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
    err "reconnect: " . $_[ARG0];
    $kernel->delay( autoping => undef );
    $kernel->delay( connect  => 60 );
}
