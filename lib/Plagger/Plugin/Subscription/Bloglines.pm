package Plagger::Plugin::Subscription::Bloglines;
use strict;
use base qw( Plagger::Plugin );

our $VERSION = '0.10';
use WebService::Bloglines;

sub plugin_id {
    my $self = shift;
    $self->class_id . '-' . $self->conf->{username};
}

sub register {
    my($self, $context) = @_;

    $self->init_bloglines();

    if ($self->conf->{no_sync_api}) {
        $context->register_hook(
            $self,
            'subscription.load' => \&getsubs,
        );
    } else {
        $context->register_hook(
            $self,
            'subscription.load' => \&notifier,
        );
    }
}

sub getsubs {
    my($self, $context) = @_;
    my $subscription = $self->{bloglines}->listsubs();

    for my $folder ($subscription->folders, 0) {
        my $subid = $folder ? $folder->{BloglinesSubId} : 0;
        my $title = $folder ? $folder->{title} : undef;
        $self->add_subscription($subscription, $subid, $title);
    }
}

sub add_subscription {
    my($self, $subscription, $subid, $title) = @_;

    my @feeds = $subscription->feeds_in_folder($subid);
    for my $source (@feeds) {
        my $feed = Plagger::Feed->new;
        $feed->title($source->{title});
        $feed->link($source->{htmlUrl});
        $feed->url($source->{xmlUrl} );
        $feed->tags([ $title ]) if $title;
        Plagger->context->subscription->add($feed);
    }
}

sub init_bloglines {
    my $self = shift;
    $self->{bloglines} = WebService::Bloglines->new(
        username => $self->conf->{username},
        password => $self->conf->{password},
        use_liberal => 1,
    );
}

sub notifier {
    my($self, $context) = @_;

    my $count = $self->{bloglines}->notify();
    $context->log(info => "You have $count unread item(s) on Bloglines.");
    if ($count) {
        my $feed = Plagger::Feed->new;
        $feed->aggregator(sub { $self->sync(@_) });
        $context->subscription->add($feed);

        if ($self->conf->{fetch_meta}) {
            $self->{bloglines_meta} = $self->cache->get_callback(
                'listsubs_meta',
                sub { $self->fetch_meta($context) },
                '1 day',
            );
        }
    }
}

sub fetch_meta {
    my($self, $context) = @_;

    $self->{folders} = {};
    $context->log(info => "call Bloglines listsubs API to get folder structure");

    my $subscription = $self->{bloglines}->listsubs();

    my $meta;
    for my $folder ($subscription->folders, 0) {
        my $subid = ref $folder ? $folder->{BloglinesSubId} : 0;
        my @feeds = $subscription->feeds_in_folder($subid);
        for my $feed (@feeds) {
            $meta->{$feed->{htmlUrl}} = {
                folder => $folder ? $folder->{title} : undef,
                xmlUrl => $feed->{xmlUrl},
                subid  => $feed->{BloglinesSubId},
            };
        }
    }

    $meta;
}

sub sync {
    my($self, $context, $args) = @_;

    my $mark_read = $self->conf->{mark_read};
       $mark_read = 1 unless defined $mark_read;

    my @updates;

    # catch bad XML feed by Bloglines
    eval {
        @updates = $self->{bloglines}->getitems(0, $mark_read);
    };

    if ($@) {
        $context->log(warn => "Bloglines Sync API returned bad XML. fallbacks to loop mode");
        my @feeds = $self->{bloglines}->listsubs()->feeds;
        for my $feed (@feeds) {
            if ($feed->{BloglinesUnread}) {
                $context->log(debug => "Fetch $feed->{BloglinesSubId}");
                push @updates, eval { $self->{bloglines}->getitems($feed->{BloglinesSubId}, $mark_read) };
            }
        }
    }

    $context->log(info => scalar(@updates) . " feed(s) updated.");

    for my $update (@updates) {
        my $source = $update->feed;

        my $feed = Plagger::Feed->new;
        $feed->type('bloglines');
        $feed->title($source->{title});
        $feed->link($source->{link});
        $feed->image($source->{image});
        $feed->description($source->{description});
        $feed->language($source->{language});
        $feed->author($source->{webmaster});
        $feed->meta->{bloglines_id} = $source->{bloglines}->{siteid};

        # under fetch_pfolders option, set folder as tags to feeds
        if (my $meta = $self->{bloglines_meta}->{$feed->link}) {
            $feed->tags([ $meta->{folder} ]) if $meta->{folder};
            $feed->url($meta->{xmlUrl});
            $feed->meta->{bloglines_subid} = $meta->{subid};
        }

        $feed->source_xml($update->{_xml});

        for my $item ( $update->items ) {
            my $entry = Plagger::Entry->new;

            $entry->title($item->{title});
            $entry->author($item->{dc}->{creator});
            $entry->tags([ $item->{dc}->{subject} ])
                if $item->{dc}->{subject};
            $entry->date( Plagger::Date->parse('Mail', $item->{pubDate}) );
            $entry->link($item->{link});

            if ($item->{guid}) {
                my $is_permalink = eval { $item->{guid}->{isPermaLink}  } ||
		    'false';
                my $guid_url     = "$item->{guid}"; # stringify MagicElement
                $entry->permalink($guid_url)
                    if $guid_url =~ m!^https?://! && $is_permalink eq 'true';
            }

            $entry->feed_link($feed->link);
            $entry->id($item->{guid});
            $entry->body($item->{description});

            if ($item->{enclosure}) {
                my $enclosure = Plagger::Enclosure->new;
                $enclosure->url( URI->new($item->{enclosure}->{url}) );
                $enclosure->length($item->{enclosure}->{length});
                $enclosure->auto_set_type($item->{enclosure}->{type});
                $entry->add_enclosure($enclosure);
            }

            $feed->add_entry($entry);
        }

        $context->update->add($feed);
    }
}

1;

__END__

=head1 NAME

Plagger::Plugin::Subscription::Bloglines - Bloglines Subscription

=head1 SYNOPSIS

  - module: Subscription::Bloglines
    config:
      username: your-email@account
      password: your-password
      mark_read: 1

=head1 DESCRIPTION

This plugin allows you to synchronize your subscription using
Bloglines Web Services sync API.

=head1 CONFIGURATION

=over 4

=item username, password

Your username & password to use with Bloglines API.

=item mark_read

C<mark_read> specifies whether this plugin I<marks as read> the items
you synchronize. With this option set to 0, you will get the
duplicated updates everytime you run Plagger, until you mark them
unread using Bloglines browser interface. Defaults to 1.

For people who uses Bloglines browser interface regularly, and use
Plagger as a tool to synchronize feed updates to mobile devices (like
PSP or iPod), I'd recommend set this option to 0.

Otherwise, especially for Publish::Gmail plugin users, I recommend set
to 1, the default.

=item fetch_meta

C<fetch_meta> specifies whether this plugin fetches I<folder>
strucuture using listsubs API. With this option on, all feeds under
I<Plagger> folder will have I<Plagger> as its tag.

You can use this tags information using Rules in later phase.

=back

=head1 AUTHOR

Tatsuhiko Miyagawa

=head1 SEE ALSO

L<Plagger>, L<WebService::Bloglines>, L<http://www.bloglines.com/>

=cut

