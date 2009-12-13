package Plagger::Plugin::Aggregator::Simple;
use strict;
use base qw( Plagger::Plugin );

use Feed::Find;
use Plagger::Enclosure;
use Plagger::UserAgent;
use List::Util qw(first);
use UNIVERSAL::require;
use URI;
use XML::Feed;
use XML::Feed::RSS;

$XML::Feed::RSS::PREFERRED_PARSER = first { $_->require } qw( XML::RSS::Liberal XML::RSS::LibXML XML::RSS );

sub register {
    my($self, $context) = @_;
    $context->register_hook(
        $self,
        'customfeed.handle'  => \&aggregate,
    );
}

sub aggregate {
    my($self, $context, $args) = @_;

    my $url = $args->{feed}->url;
    my $res = $self->fetch_content($url) or return;

    my $content_type = eval { $res->content_type } ||
                       $res->http_response->content_type ||
                       "text/xml";

    $content_type =~ s/;.*$//; # strip charset= cruft

    my $content = $res->content;
    if ( $Feed::Find::IsFeed{$content_type} || $self->looks_like_feed(\$content) ) {
        $self->handle_feed($url, \$content, $args->{feed});
    } else {
        $content = Plagger::Util::decode_content($res);
        my @feeds = Feed::Find->find_in_html(\$content, $url);
        if (@feeds) {
            $url = $feeds[0];
            $res = $self->fetch_content($url) or return;
            $self->handle_feed($url, \$res->content, $args->{feed});
        } else {
            return;
        }
    }

    return 1;
}

sub looks_like_feed {
    my($self, $content_ref) = @_;
    $$content_ref =~ m!<rss |<rdf:RDF\s+.*?xmlns="http://purl\.org/rss|<feed\s+xmlns="!s;
}

sub fetch_content {
    my($self, $url) = @_;

    my $context = Plagger->context;
    $context->log(info => "Fetch $url");

    my $agent = Plagger::UserAgent->new;
       $agent->parse_head(0);
    my $response = $agent->fetch($url, $self);

    if ($response->is_error) {
        $context->log(error => "GET $url failed: " .
                      $response->http_status . " " .
                      $response->http_response->message);
        return;
    }

    # TODO: handle 301 Moved Permenently and 410 Gone
    $context->log(debug => $response->status . ": $url");

    $response;
}

sub handle_feed {
    my($self, $url, $xml_ref, $feed) = @_;

    my $context = Plagger->context;

    my $args = { content => $$xml_ref };
    $context->run_hook('aggregator.filter.feed', $args);

    # override XML::LibXML with Liberal
    my $sweeper; # XML::Liberal >= 0.13

    eval { require XML::Liberal };
    if (!$@ && $XML::Liberal::VERSION >= 0.10) {
        $sweeper = XML::Liberal->globally_override('LibXML');
    }

    my $remote = eval { XML::Feed->parse(\$args->{content}) };

    unless ($remote) {
        $context->log(error => "Parsing $url failed. " . ($@ || XML::Feed->errstr));
        return;
    }

    $feed ||= Plagger::Feed->new;
    $feed->title(_u($remote->title)) unless defined $feed->title;
    $feed->url($url);
    $feed->link($remote->link);
    $feed->description(_u($remote->tagline)); # xxx should support Atom 1.0
    $feed->language($remote->language);
    $feed->author(_u($remote->author));
    $feed->updated($remote->modified);
    $feed->source_xml($$xml_ref);

    if ($remote->format eq 'Atom') {
        $feed->id( $remote->{atom}->id );
    }

    if ($remote->format =~ /^RSS/) {
        $feed->image( $remote->{rss}->image )
            if $remote->{rss}->image;
    } elsif ($remote->format eq 'Atom') {
        $feed->image({ url => $remote->{atom}->logo })
            if $remote->{atom}->logo;
    }

    for my $e ($remote->entries) {
        my $entry = Plagger::Entry->new;
        $entry->title(_u($e->title));
        $entry->author(_u($e->author));

        my $category = $e->category;
           $category = [ $category ] if $category && !ref($category);
        $entry->tags([ map _u($_), @$category ]) if $category;

        $entry->date( Plagger::Date->rebless($e->issued) )
            if eval { $e->issued };

        # xxx nasty hack. We should remove this once XML::Atom or XML::Feed is fixed
        if (!$entry->date && $remote->format eq 'Atom' && $e->{entry}->version eq '1.0') {
            if ( $e->{entry}->published ) {
                my $dt = XML::Atom::Util::iso2dt( $e->{entry}->published );
                $entry->date( Plagger::Date->rebless($dt) ) if $dt;
            }
        }

        $entry->link($e->link);
        $entry->feed_link($feed->link);
        $entry->id($e->id);
        $entry->body(_u($e->content->body || $e->summary->body));

        # enclosure support, to be added to XML::Feed
        if ($remote->format =~ /^RSS / and my $encls = $e->{entry}->{enclosure}) {
            # some RSS feeds contain multiple enclosures, and we support them
            $encls = [ $encls ] unless ref $encls eq 'ARRAY';

            for my $encl (@$encls) {
                my $enclosure = Plagger::Enclosure->new;
                $enclosure->url( URI->new($encl->{url}) );
                $enclosure->length($encl->{length});
                $enclosure->auto_set_type($encl->{type});
                $entry->add_enclosure($enclosure);
            }
        } elsif ($remote->format eq 'Atom') {
            for my $link ( grep { $_->rel eq 'enclosure' } $e->{entry}->link ) {
                my $enclosure = Plagger::Enclosure->new;
                $enclosure->url( URI->new($link->href) );
                $enclosure->length($link->length);
                $enclosure->auto_set_type($link->type);
                $entry->add_enclosure($enclosure);
            }
        }

        # TODO: move MediaRSS, Hatena, iTunes and those specific parser to be subclassed

        # Media RSS
        my $media_ns = "http://search.yahoo.com/mrss";
        my $media = $e->{entry}->{$media_ns}->{group} || $e->{entry};
        my $content = $media->{$media_ns}->{content} || [];
           $content = [ $content ] unless ref $content;

        for my $media_content (@{$content}) {
            my $enclosure = Plagger::Enclosure->new;
            $enclosure->url( URI->new($media_content->{url}) );
            $enclosure->auto_set_type($media_content->{type});
            $entry->add_enclosure($enclosure);
        }

        if (my $thumbnail = $media->{$media_ns}->{thumbnail}) {
            $entry->icon({
                url   => $thumbnail->{url},
                width => $thumbnail->{width},
                height => $thumbnail->{height},
            });
        }

        # Hatena Image extensions
        my $hatena = $e->{entry}->{"http://www.hatena.ne.jp/info/xmlns#"} || {};
        if ($hatena->{imageurl}) {
            my $enclosure = Plagger::Enclosure->new;
            $enclosure->url($hatena->{imageurl});
            $enclosure->auto_set_type;
            $entry->add_enclosure($enclosure);
        }

        if ($hatena->{imageurlsmall}) {
            $entry->icon({ url   => $hatena->{imageurlsmall} });
        }

        # Apple photocast feed
        my $apple = $e->{entry}->{"http://www.apple.com/ilife/wallpapers"} || {};
        if ($apple->{image}) {
            my $enclosure = Plagger::Enclosure->new;
            $enclosure->url( URI->new($apple->{image}) );
            $enclosure->auto_set_type;
            $entry->add_enclosure($enclosure);
        }
        if ($apple->{thumbnail}) {
            $entry->icon({ url => $apple->{thumbnail} });
        }

        my $args = {
            entry      => $entry,
            feed       => $feed,
            orig_entry => $e,
            orig_feed  => $remote,
        };
        $context->run_hook('aggregator.entry.fixup', $args);

        $feed->add_entry($entry);
    }

    $context->log(info => "Aggregate $url success: " . $feed->count . " entries.");
    $context->update->add($feed);
}

sub _u {
    my $str = shift;
    Encode::_utf8_on($str);
    $str;
}

1;

__END__

=head1 NAME

Plagger::Plugin::Aggregator::Simple - Dumb simple aggregator

=head1 SYNOPSIS

  - module: Aggregator::Simple

=head1 DESCRIPTION

This plugin implements a Plagger dumb aggregator. It crawls
subscription sequentially and parses XML feeds using L<XML::Feed>
module.

It can be also used as a base class for custom aggregators. See
L<Plagger::Plugin::Aggregator::Xango> for example.

=head1 AUTHOR

Tatsuhiko Miyagawa

=head1 SEE ALSO

L<Plagger>, L<XML::Feed>, L<XML::RSS::LibXML>

=cut
