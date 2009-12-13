# $Id: /mirror/plagger/trunk/plagger/lib/Plagger/Plugin/Aggregator/Xango.pm 25225 2006-03-05T17:31:45.515672Z miyagawa  $
#
# Copyright (c) 2006 Daisuke Maki <dmaki@cpan.org>
# All rights reserved.

package Plagger::Plugin::Aggregator::Xango;
use strict;
use base qw( Plagger::Plugin::Aggregator::Simple );
use POE;
use Xango::Broker::Push;
# sub Xango::DEBUG { 1 } # uncomment to get Xango debug messages

sub register {
    my($self, $context) = @_;

    my %xango_args = (
        Alias => 'xgbroker',
        HandlerAlias => 'xghandler',
        HttpCompArgs => [ Agent => "Plagger/$Plagger::VERSION (http://plagger.org/)" ],
        %{$self->conf->{xango_args} || {}},
    );
    $self->{xango_alias} = $xango_args{Alias};
    Plagger::Plugin::Aggregator::Xango::Crawler->spawn(
        Plugin => $self,
        UseCache => exists $self->conf->{use_cache} ?
            $self->conf->{use_cache} : 1,
    );
    Xango::Broker::Push->spawn(%xango_args);
    $context->register_hook(
        $self,
        'aggregator.aggregate.feed' => \&aggregate,
        'aggregator.finalize'       => \&finalize,
    );
}

sub aggregate {
    my($self, $context, $args) = @_;

    my $url = $args->{feed}->url;
    $context->log(info => "Fetch $url");
    POE::Kernel->post($self->{xango_alias}, 'enqueue_job', Xango::Job->new(uri => URI->new($url)));
}

sub finalize {
    my($self, $context, $args) = @_;
    POE::Kernel->run;
}

package Plagger::Plugin::Aggregator::Xango::Crawler;
use strict;
use POE;
use Storable qw(freeze thaw);
use XML::Feed;

sub apply_policy { 1 }
sub spawn  {
    my $class = shift;
    my %args  = @_;

    POE::Session->create(
        heap => { PLUGIN => $args{Plugin}, USE_CACHE => $args{UseCache} },
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

    my $r = $job->notes('http_response');
    my $url    = $job->uri;

    return unless $r->is_success;
    $plugin->handle_feed($url, $r->content_ref);
    if ($_[HEAP]->{USE_CACHE}) {
        $plugin->cache->set(
            $job->uri,
            {ETag => $r->header('ETag'),
                LastModified => $r->header('Last-Modified')}
        );
    }
}

1;

