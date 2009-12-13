package Plagger::Plugin::CustomFeed::YouTube;
use strict;
use warnings;
use base qw( Plagger::Plugin );

use Plagger::Enclosure;
use Plagger::UserAgent;

sub register {
    my($self, $context) = @_;
    $context->register_hook(
        $self,
        'subscription.load' => \&load,
    );
}

sub load {
    my($self, $context) = @_;
    my $feed = Plagger::Feed->new;
    $feed->aggregator(sub { $self->aggregate(@_) });
    $context->subscription->add($feed);
}

sub aggregate {
    my($self, $context, $args) = @_;

    my $q = $self->conf->{query};
    $q =~ s/\s/\+/g;

    my $file = $self->cache->path_to('youtube_search_result.html');

    $context->log( info => 'Getting YouTube search results for ' . $self->conf->{query} );

    my $ua = Plagger::UserAgent->new;

    my $feed = Plagger::Feed->new;
    $feed->type('youtubesearch');
    $feed->title('YouTube Search - ' . $self->conf->{query});

    my $page = $self->conf->{page} || 1;
    my $sort = $self->conf->{sort} || 'video_date_uploaded';
    for ( 1 .. $page ){
        my $res = $ua->mirror("http://youtube.com/results?search=$q&sort=$sort&page=$_" => $file);

        if($res->is_error){
            $context->log( error => $res->status_line );
            return;
        }

        open my $fh, "<:encoding(utf-8)", $file
            or return $context->log(error => "$file: $!");

        my (@videos, $data, $title_flag, $tag_flag);
        while (<$fh>) {
            # get title
            m!<div class="title">!
                and $title_flag = 1;
            m!<a href="/watch\?v=([^&]+)&search=[^>]+">(.+)</a>!
                and do {
                    if($title_flag){
                        $data->{title} = $2;
                        $data->{id} = $1;
                        $title_flag = 0;
                    }
                };
            m!<img src="(http://static\d+.youtube.com/[^">]+/1.jpg)" class="vimgSm" />!
                and $data->{image}->{url} = $1;
            m!<div class="desc">(.*)</div>!
                and $data->{description} = $1;
            m!<td><span class="grayText">Tags:</span></td>!
                and $tag_flag = 1;
            m!(<td><a href="/results\?search=.*)!
                and do {
                    if($tag_flag){
                        $data->{tags} = $1;
                        $tag_flag = 0;
                    }
                };
            m!profile\?user=([^"]+)!
                and do {
                    $context->log( info => 'Got ' . $data->{title});
                    $data->{author} = $1;
                    my $entry = Plagger::Entry->new;
                    $entry->title($data->{title});
                    $entry->link('http://youtube.com/watch?v=' . $data->{id});
                    $entry->icon({
                        url    => $data->{image}->{url},
                        #width  => $data->{image}->{width},
                        #height => $data->{image}->{height},
                    });
                    $entry->summary($data->{description});
                    $entry->body($data->{description});
                    $entry->author($data->{author});

                    # tags
                    while( $data->{tags} =~ /<a href="\/results\?search=.*">(.*)<\/a>/gms){
                        $entry->add_tag($1);
                    }

                    # enclosure
                    my $video_url = $self->cache->get_callback(
                        "item-" . $entry->link, sub {
                            my $res = $ua->fetch($entry->link);
                            if ($res->is_error){
                                $context->log( error => $res->status_line );
                                return;
                            }
                            my $url;
                            if ($res->content =~ /&t=([^&]+)/gms){
                                $url = 'http://youtube.com/get_video?video_id=' . $data->{id} . "&t=$1";
                            }
                            return $url;
                        },
                        '24 hours',
                    );

                    if ($video_url) {
                        my $video_id = ( $video_url =~ /video_id=(\w+)/ )[0];

                        my $enclosure = Plagger::Enclosure->new;
                        $enclosure->url( URI->new($video_url) );
                        $enclosure->type('video/flv');
                        $enclosure->filename("$video_id.flv");
                        $entry->add_enclosure($enclosure);
                    }

                    $feed->add_entry($entry);
                    $data = {};
            };
        }
    }

    $context->update->add($feed);
}

1;
__END__

=head1 NAME

Plagger::Plugin::CustomFeed::YouTube - Get YouTube search result or rss

=head1 SYNOPSIS

  - module: CustomFeed::YouTube
    config:
      query: Twenty Four
      sort: video_date_uploaded
      page: 5

=head1 DESCRIPTION

This plugin fetches the result of YouTube search or the rss of a specified tag.

=head1 CONFIG

=over 4

=item query

Specify search query.

=item sort

Set sort condition. Available condisions are below. Default is video_date_uploaded.

  relevance
  video_date_uploaded
  title_sort
  n video_view_count
  rating_sort

=item page

Number of pages of search result you get. Default is 1.

=back

=head1 AUTHOR

Gosuke Miyashita

=head1 SEE ALSO

L<Plagger>

=cut
