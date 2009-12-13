package Plagger::Util;
use strict;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw( strip_html dumbnail decode_content extract_title );

use Encode ();
use List::Util qw(min);
use HTML::Entities;

our $Detector;

BEGIN {
    if ( eval { require Encode::Detect::Detector; 1 } ) {
        $Detector = sub { Encode::Detect::Detector::detect($_[0]) };
    } else {
        require Encode::Guess;
        $Detector = sub {
            my @guess = qw(utf-8 euc-jp shift_jis); # xxx japanese only?
            eval { Encode::Guess::guess_encoding($_[0], @guess)->name };
        };
    }
}

sub strip_html {
    my $html = shift;
    $html =~ s/<[^>]*>//g;
    HTML::Entities::decode($html);
}

sub dumbnail {
    my($img, $p) = @_;

    if (!$img->{width} && !$img->{height}) {
        return '';
    }

    if ($img->{width} <= $p->{width} && $img->{height} <= $p->{height}) {
        return qq(width="$img->{width}" height="$img->{height}");
    }

    my $ratio_w = $p->{width}  / $img->{width};
    my $ratio_h = $p->{height} / $img->{height};
    my $ratio   = min($ratio_w, $ratio_h);

    sprintf qq(width="%d" height="%d"), ($img->{width} * $ratio), ($img->{height} * $ratio);
}

sub decode_content {
    my $res = shift;
    my $content = $res->content;

    # 1) get charset from HTTP Content-Type header
    my $charset = ($res->http_response->content_type =~ /charset=([\w\-]+)/)[0];

    # 2) if there's not, try META tag
    $charset ||= ( $content =~ m!<meta http-equiv="Content-Type" content=".*charset=([\w\-]+)"!i )[0];

    # 3) if there's not still, try Detector/Guess
    $charset ||= $Detector->($content);

    # 4) falls back to UTF-8
    $charset ||= 'utf-8';

    my $decoded = eval { Encode::decode($charset, $content) };

    if ($@ && $@ =~ /Unknown encoding/) {
        Plagger->context->log(warn => $@);
        $charset = $Detector->($content) || 'utf-8';
        $decoded = Encode::decode($charset, $content);
    }

    $decoded;
}

sub extract_title {
    my $content = shift;
    my $title = ($content =~ m!<title>\s*(.*?)\s*</title>!s)[0] or return;
    HTML::Entities::decode($1);
}

1;
