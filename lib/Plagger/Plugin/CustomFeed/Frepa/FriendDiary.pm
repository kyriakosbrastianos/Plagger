package Plagger::Plugin::CustomFeed::Frepa::FriendDiary;
use strict;
use warnings;
use HTML::Entities;
use Encode;

sub title { 'フレ友の日記' }

sub start_url { 'http://www.frepa.livedoor.com/home/friend_blog/' }

sub get_list {
    my ($self, $mech) = @_;

    my @msgs = ();
    my $res = $mech->get($self->start_url);
    return @msgs unless $mech->success;

    my $html = decode('euc-jp', $mech->content);
    my $reg  = decode('utf-8', $self->_list_regexp());
    while ($html =~ m|$reg|igs) {
        my $time = "$1/$2/$3 $4:$5";
        my ($link, $subject, $user_link, $name) =
            (decode_entities($6), decode_entities($7), decode_entities($8), decode_entities($9));

        push(@msgs, +{
            link      => $link,
            subject   => $subject,
            name      => $name,
            user_link => $user_link,
            time      => $time,
        });
    }
    return @msgs;
}

sub get_detail {
    my ($self, $link, $mech) = @_;

    my $item = {};
    my $res = $mech->get($link);
    return $item unless $mech->success;

    my $html = decode('euc-jp', $mech->content);
    my $reg  = decode('utf-8', $self->_detail_regexp);
    if ($html =~ m|$reg|is) {
        $item = +{ subject => $6, description => $7};
    }

    return $item;
}

sub _list_regexp {
    return <<'RE';
<tr class="bgwhite">
<td width="1%" style="padding:5px 30px;" nowrap><small>(\d\d\d\d)\.(\d\d)\.(\d\d) (\d\d):(\d\d)</small></td>
<td width="99%"><img src="/img/icon/diary_fp.gif" border="0" alt=".*?" title=".*?">
<small>



<a href="([^"]+?/blog/show[^"]+?)">(.*?)</a>.*?
<a href="([^"]+?)"(?: rel="popup")?>([^"]+?)</a>.*?
RE
}

sub _detail_regexp {
    return <<'RE';
<td width="105" valign="top" rowspan="3" class="bg2 blogline1" nowrap><small>(\d\d\d\d)\.(\d\d)\.(\d\d)<br>(\d\d):(\d\d)</small></td>
<td width="445" class="bg2 blogline3 blogcell"><small><strong>(.*?)</strong></small></td>
</tr>
<tr>
<td class="bgwhite blogline2" style="line-height:115%;border-bottom:1px solid #fff;"><small>(.*?)</small></td>
</tr>

</table>
RE
}

1;
