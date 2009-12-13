package Plagger::Plugin::Filter::StripRSSAd;
use strict;
use base qw( Plagger::Plugin );

use DirHandle;

sub init {
    my $self = shift;
    $self->SUPER::init(@_);
    Plagger->context->autoload_plugin('Filter::BloglinesContentNormalize');
    $self->load_patterns();
}

sub load_patterns {
    my $self = shift;

    my $dir = $self->assets_dir;
    my $dh = DirHandle->new($dir) or Plagger->context->error("$dir: $!");
    for my $file (grep -f $_->[0] && $_->[1] =~ /^[\w\-\.]+$/,
                  map [ File::Spec->catfile($dir, $_), $_ ], sort $dh->read) {
        $self->load_pattern(@$file);
    }
}

sub load_pattern {
    my($self, $file, $base) = @_;

    Plagger->context->log(debug => "loading $file");

    if ($file =~ /\.yaml$/) {
        $self->load_yaml($file, $base);
    } else {
        $self->load_regexp($file, $base);
    }
}

sub load_regexp {
    my($self, $file, $base) = @_;

    open my $fh, $file or Plagger->context->error("$file: $!");
    my $re = join '', <$fh>;
    chomp($re);

    push @{$self->{pattern}}, { site => $base, re => qr/$re/ };
}

sub load_yaml {
    my($self, $file, $base) = @_;

    my $pattern = eval { YAML::LoadFile($file) }
        or Plagger->context->error("$file: $@");

    push @{$self->{pattern}}, { site => $base, %$pattern };
}

sub register {
    my($self, $context) = @_;
    $context->register_hook(
        $self,
        'update.entry.fixup' => \&update,
    );
}

sub update {
    my($self, $context, $args) = @_;
    my $body = $args->{entry}->body;

    for my $pattern (@{ $self->{pattern} }) {
        if (my $re = $pattern->{re}) {
            if (my $count = $body =~ s!$re!defined($1) ? $1 : ''!egs) {
                Plagger->context->log(info => "Stripped $pattern->{site} Ad on " . $args->{entry}->link);
            }
        } elsif (my $cond = $pattern->{condition}) {
            local $args->{body} = $body;
            if (eval $cond && $pattern->{strip}) {
                $args->{feed}->delete_entry($args->{entry});
                Plagger->context->log(info => "Stripped Ad entry " . $args->{entry}->link);
            } elsif ($@) {
                Plagger->context->log(error => "Error evaluating $cond: $@");
            }
        }
    }

    $args->{entry}->body($body);
}

1;

__END__

=head1 NAME

Plagger::Plugin::Filter::StripRSSAd - Strip RSS Ads from feed content

=head1 SYNOPSIS

  - module: Filter::StripRSSAd

=head1 DESCRIPTION

This plugin strips RSS context based ads from feed content, like
Google AdSense or rssad.jp. It uses quick regular expression to strip
the images and map tags.

=head1 AUTHOR

Tatsuhiko Miyagawa, Masahiro Nagano

=head1 SEE ALSO

L<Plagger>

=cut
