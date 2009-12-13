package Plagger::Plugin::Filter::URLBL;
use strict;
use base qw( Plagger::Plugin );

our $VERSION = '0.10';

use Net::DNS::Resolver;
use URI::Find;
use URI;

sub register {
    my($self, $context) = @_;
    $context->register_hook(
        $self,
        'update.fixup' => \&filter,
    );
}

sub filter {
    my($self, $context, $args) = @_;

    for my $feed ($context->update->feeds) {
        for my $entry ($feed->entries) {
            $self->urlbl_filter($context, $entry);
        }
    }
}

sub urlbl_filter {
    my($self, $context, $entry) = @_;

    my @urls;
    my $finder = URI::Find->new(
        sub {
            my($uri, $orig_uri) = @_;
            if ($orig_uri =~ m!^https?://!) {
                push @urls, $uri;
            }
            return $orig_uri;
        },
    );

    my $content = $entry->text;
    $finder->find(\$content);

    my $res = Net::DNS::Resolver->new;
    my $dnsbl = $self->conf->{dnsbl};
       $dnsbl = [ $dnsbl ] unless ref $dnsbl;

    for my $url (@urls) {
        my $uri = URI->new($url);
        my $domain = $uri->host;
        $domain =~ s/^www\.//;

        next if $self->{__done}->{$domain}++;

        for my $dns (@$dnsbl) {
            $context->log(debug => "looking up $domain.$dns");
            my $q = $res->search("$domain.$dns");
            if ($q && $q->answer) {
                my $rate = $self->conf->{rate} || -1;
                $context->log(warn => "$domain.$dns found. Add rate $rate");
                $entry->add_rate($rate);
            }
        }
    }
}

1;
