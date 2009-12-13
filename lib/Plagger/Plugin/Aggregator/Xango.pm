# $Id: /mirror/plagger/trunk/plagger/lib/Plagger/Plugin/Aggregator/Xango.pm 2173 2006-05-05T07:51:03.432950Z miyagawa  $
#
# Copyright (c) 2006 Daisuke Maki <dmaki@cpan.org>
# All rights reserved.

package Plagger::Plugin::Aggregator::Xango;
use strict;
use base qw( Plagger::Plugin::Aggregator::Simple );
use POE;
use Xango::Broker::Push;
# BEGIN { sub Xango::DEBUG { 1 } } # uncomment to get Xango debug messages

our $VERSION = '0.1';

sub register {
    my($self, $context) = @_;

    my %xango_args = (
        Alias => 'xgbroker',
        HandlerAlias => 'xghandler',
        HttpCompArgs => [ Agent => "Plagger/$Plagger::VERSION (http://plagger.org/)", Timeout => $self->conf->{timeout} || 10 ],
        %{$self->conf->{xango_args} || {}},
    );
    $self->{xango_alias} = $xango_args{Alias};
    Plagger::Plugin::Aggregator::Xango::Crawler->spawn(
        Plugin => $self,
        UseCache => exists $self->conf->{use_cache} ?
            $self->conf->{use_cache} : 1,
        BrokerAlias => $xango_args{Alias},
        MaxRedirect => $self->conf->{max_redirect} || 3,
    );
    Xango::Broker::Push->spawn(%xango_args);
    $context->register_hook(
        $self,
        'customfeed.handle'   => \&aggregate,
        'aggregator.finalize' => \&finalize,
    );
}

sub aggregate {
    my($self, $context, $args) = @_;

    my $url = $args->{feed}->url;
    return unless $url =~ m!^https?://!i;

    $self->{_url2feed}->{$url} = $args->{feed}; # map from url to feed object

    $context->log(info => "Fetch $url");
    POE::Kernel->post($self->{xango_alias}, 'enqueue_job', Xango::Job->new(uri => URI->new($url), redirect => 0));
}

sub handle_feed {
    my($self, $url, $xml_ref) = @_;
    $self->SUPER::handle_feed($url, $xml_ref, $self->{_url2feed}->{$url});
}

sub finalize {
    my($self, $context, $args) = @_;
    POE::Kernel->run;
}

package Plagger::Plugin::Aggregator::Xango::Crawler;
use strict;
use Feed::Find;
use POE;
use Storable qw(freeze thaw);
use XML::Feed;

sub apply_policy { 1 }
sub spawn  {
    my $class = shift;
    my %args  = @_;

    POE::Session->create(
        heap => {
            PLUGIN => $args{Plugin}, USE_CACHE => $args{UseCache},
            BROKER_ALIAS => $args{BrokerAlias},
            MaxRedirect => $args{MaxRedirect},
        },
        package_states => [
            $class => [ qw(_start _stop apply_policy prep_request handle_response) ]
        ]
    );
}

sub _start { $_[KERNEL]->alias_set('xghandler') }
sub _stop  { }
sub prep_request {
    return unless $_[HEAP]->{USE_CACHE};

    my $job = $_[ARG0];
    my $req = $_[ARG1];
    my $plugin = $_[HEAP]->{PLUGIN};

    my $ref = $plugin->cache->get($job->uri);
    if ($ref) {
        $req->if_modified_since($ref->{LastModified})
            if $ref->{LastModified};
        $req->header('If-None-Match', $ref->{ETag})
            if $ref->{ETag};
    }
}

sub handle_response {
    my $job = $_[ARG0];
    my $plugin = $_[HEAP]->{PLUGIN};

    my $redirect = $job->notes('redirect') + 1;
    return if $redirect > $_[HEAP]->{MaxRedirect};

    my $r = $job->notes('http_response');
    my $url    = $job->uri;
    if ($r->code =~ /^30[12]$/) {
        $url = $r->header('location');
        return unless $url =~ m!^https?://!i;
        $_[KERNEL]->post($_[HEAP]->{BROKER_ALIAS}, 'enqueue_job', Xango::Job->new(uri => URI->new($url), redirect => $redirect));
	return;
    } else {
        return unless $r->is_success;

        my $ct = $r->content_type;
        if ( $Feed::Find::IsFeed{$ct} ) {
            $plugin->handle_feed($url, $r->content_ref);
        } else {
            my @feeds = Feed::Find->find_in_html($r->content_ref, $url);
            if (@feeds) {
                my $feed_url = $feeds[0];
                return unless $feed_url =~ m!^https?://!i;

                # OMG we should alias Feed so it can be looked up with $feed_url, too
                $plugin->{_url2feed}->{$feed_url} = $plugin->{_url2feed}->{$url};

                $_[KERNEL]->post($_[HEAP]->{BROKER_ALIAS}, 'enqueue_job', Xango::Job->new(uri => URI->new($feed_url), redirect => $redirect));
            }
            return;
        }
    }

    if ($_[HEAP]->{USE_CACHE}) {
        $plugin->cache->set(
            $job->uri,
            {ETag => $r->header('ETag'),
                LastModified => $r->header('Last-Modified')}
        );
    }
}

1;

