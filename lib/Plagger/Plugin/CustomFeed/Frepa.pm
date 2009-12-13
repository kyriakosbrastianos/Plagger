package Plagger::Plugin::CustomFeed::Frepa;
use strict;
use base qw( Plagger::Plugin );

use DateTime::Format::Strptime;
use Encode;
use Time::HiRes;
use UNIVERSAL::require;
use Plagger::Mechanize;

sub plugin_id {
    my $self = shift;
    $self->class_id . '-' . $self->conf->{livedoor_id};
}

sub register {
    my ($self, $context) = @_;
    $context->register_hook(
        $self,
        'subscription.load' => \&load,
    );
}

sub load {
    my ($self, $context) = @_;

    $self->{mech} = Plagger::Mechanize->new(cookie_jar => $self->cookie_jar);

    my $feed = Plagger::Feed->new;
    $feed->aggregator(sub { $self->aggregate(@_) });
    $context->subscription->add($feed);
}

sub aggregate {
    my ($self, $context, $args) = @_;

    unless ($self->login(livedoor_id => $self->conf->{livedoor_id}, password => $self->conf->{password})) {
        $context->log(error => "Login to frepa failed.");
        return;
    }

    $context->log(info => 'Login to frepa succeeded.');

    my $feed_type = $self->conf->{feed_type} || [ qw(FriendDiary FriendStatus RecentComment) ];
    for my $plugin (@$feed_type) {
        my $plugin = (ref $self || $self) . "::$plugin";
        $plugin->require or $context->error($@);
        $self->aggregate_by_plugin($context, $plugin, $args);
    }
}

sub aggregate_by_plugin {
    my ($self, $context, $plugin, $args) = @_;

    my $feed = Plagger::Feed->new;
    $feed->type('frepa');
    $feed->title($plugin->title);
    $feed->link($plugin->start_url);

    my $format = DateTime::Format::Strptime->new(pattern => '%Y/%m/%d %H:%M');

    my @msgs = $plugin->get_list($self->{mech}, $self);
    my $items = $self->conf->{fetch_items} || 20;

    my $i = 0;
    my $blocked = 0;
    for my $msg (@msgs) {
        last if $i++ >= $items;

        my $entry = Plagger::Entry->new;
        $entry->title($msg->{subject});
        $entry->link($msg->{link});
        $entry->author($msg->{name});
        $entry->date( Plagger::Date->parse($format, $msg->{time}) );

        if ($self->conf->{fetch_body} && !$blocked and $plugin->can('get_detail')) {
            $context->log(info => "Fetch body from $msg->{link}");
            my $item = $self->cache->get_callback(
                "item-$msg->{link}",
                sub {
                    Time::HiRes::sleep( $self->conf->{fetch_body_interval} || 1.5 );
                    $plugin->get_detail($msg->{link}, $self->{mech});
                },
                "1 hour",
            );
            if ($item) {
                my $body = $item->{description};
                   $body =~ s!<br>!<br />!g;
                $entry->body($body);
                $entry->title($item->{subject}); # replace with full title
            } else {
                $context->log(warn => "Fetch body failed. You might be blocked?");
                $blocked++;
            }
        }

        if ($self->conf->{show_icon} && !$blocked) {
            my $item = $self->fetch_icon($msg->{user_link});
            if ($item && $item->{image} !~ /no_photo/) {
                $entry->icon({
                    title => $item->{name},
                    url   => $item->{image},
                    link  => $msg->{user_link},
                });
            }
        }

        $feed->add_entry($entry);
    }

    $context->update->add($feed);
}

sub fetch_icon {
    my($self, $url) = @_;

    Plagger->context->log(info => "Fetch icon from $url");
    $self->cache->get_callback(
        "icon-$url",
        sub { $self->get_top($url) },
        '1 day',
    );
}

sub login {
    my $self = shift;
    my %args = @_;

    my $start_url = 'http://www.frepa.livedoor.com/';
    my $res = $self->{mech}->get($start_url);
    return unless $self->{mech}->success;

    if ($self->{mech}->content =~ /loginside/) {
        unless ($args{livedoor_id} && $args{password}) {
            Plagger->context->log(error => "Error logging in using existent Cookies. Your User-Agent (" . $self->{mech}->agent . ") should strictly match with the UA used with the Cookies.");
            return;
        }

        Plagger->context->log(debug => "cookie not found. logging in");
        $self->{mech}->submit_form(
            fields => {
                livedoor_id => $args{livedoor_id},
                password    => $args{password},
                auto_login  => 'on',
            },
        );
        $self->{mech}->submit;
        return unless $self->{mech}->success;
        return if $self->{mech}->content =~ /loginside/;
    }

    return 1;
}

sub get_top {
    my $self = shift;
    my $link = shift;

    my $item = {};
    my $res = $self->{mech}->get($link);
    return $item unless $self->{mech}->success;

    my $html = decode('euc-jp', $self->{mech}->content);

    chomp( my $re  = decode('utf-8', $self->top_re) );
    if ($html =~ /$re/s) {
        $item->{image} = $1;
        $item->{name}  = $2;
    }

    return $item;
}

sub top_re {
    return <<'RE';
<a href="http://(?:frepa\.livedoor\.com/.*?/|www\.frepa\.livedoor\.com/)"(?: rel="popup")?><img src="(http://img\d+\.(?:ico\.frepa\.livedoor\.com/member_photo/|bbs\.frepa\.livedoor\.com/community_board/).*?\.(?:jpe?g|JPE?G|gif|GIF|png|PNG))" border="0"></a>
</small>
.*?
<div id="namebody"><small><strong>(.*?)....</strong>
RE
}

1;

__END__

=head1 NAME

Plagger::Plugin::CustomFeed::Frepa - Custom feed for livedoor Frepa

=head1 SYNOPSIS

  - module: CustomFeed::Frepa
    config:
      livedoor_id: your-id
      password: password
      fetch_body: 1
      show_icon: 1
      feed_type:
        - FriendDiary
        - FriendStatus
        - RecentComment

=head1 DESCRIPTION

This plugin fetches your friend blog updates from livedoor Frepa
(L<http://frepa.livedoor.com/>) and creates a custom feed.

=head1 CONFIGURATION

See L<Plagger::Plugin::CustomFeed::Mixi> for C<fetch_body>,
C<fetch_body_interval> and C<show_icon>.

Note that you don't have to supply livedoor_id and password if you set
global cookie_jar in your configuration file and the cookie_jar
contains a valid login session there, such as:

  global:
    user_agent:
      cookies: /path/to/cookies.txt

See L<Plagger::Cookies> for details.


=head1 AUTHOR

Kazuhiro Osawa

Tokuhiro Matsuno

Tatsuhiko Miyagawa

=head1 SEE ALSO

L<Plagger>, L<Plagger::Plugin::CustomFeed::Mixi>, L<Plagger::Mechanize>,
L<http://frepa.livedoor.com/>

=cut
