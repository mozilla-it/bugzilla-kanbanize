use strict;
use warnings;

package Net::Bugzilla::Kanbanize;

#ABSTRACT: Bugzilla and Kanbanize sync tool

use Data::Dumper;

use Net::Bugzilla::Kanbanize;

use LWP::Simple;
use JSON;

use LWP::UserAgent;
use File::HomeDir;

use HTTP::Request;
use URI::Escape;
use List::MoreUtils qw(uniq);

#XXX: https://bugzil.la/970457

sub new {
    my ( $class, $config ) = @_;

    my $self = bless { config => $config }, $class;

    return $self;
}

#XXX: Wrong, need to be instance variables

my $APIKEY;
my $BOARD_ID;
my $BUGZILLA_TOKEN;
my $ua = LWP::UserAgent->new();

my $total;
my $count;
my $config;

sub run {
    my $self = shift;

    $config = $self->{config};

    $APIKEY = $config->kanbanize_apikey or die "Please configure an apikey";
    $BOARD_ID = $config->kanbanize_boardid
      or die "Please configure a kanbanize_boardid";
    $BUGZILLA_TOKEN = $config->bugzilla_token
      or die "Please configure a bugzilla_token";

    $ua->timeout(15);
    $ua->env_proxy;
    $ua->default_header( 'apikey' => $APIKEY );

    my %bugs;

    if (@ARGV) {
        fill_missing_bugs_info(\%bugs, @ARGV);
    }
    else {
        %bugs = get_bugs();
    }

    $count = scalar keys %bugs;

    print STDERR "Found a total of $count bugs\n";

    $total = 0;

    while ( my ( $bugid, $bug ) = each %bugs ) {
        sync_bug($bug);
    }

    return 1;
}

sub get_bugs {
    my $req =
      HTTP::Request->new( GET =>
"https://bugzilla.mozilla.org/rest/bug?token=$BUGZILLA_TOKEN&include_fields=id,status,whiteboard,summary,assigned_to&bug_status=UNCONFIRMED&bug_status=NEW&bug_status=ASSIGNED&bug_status=REOPENED&component=WebOps%3A Bugzilla&component=WebOps%3A Community Platform&component=WebOps%3A Engagement&component=WebOps%3A IT-Managed Tools&component=WebOps%3A Labs&component=WebOps%3A Other&component=WebOps%3A Product Delivery&component=WebOps%3A SSL and Domain Names&product=Infrastructure %26 Operations"
      );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }

    my $data = decode_json( $res->decoded_content );

    my %bugs;

    foreach my $bug ( @{ $data->{bugs} } ) {
        $bugs{ $bug->{id} } = $bug;
    }

    my @marked = get_marked_bugs();
    foreach my $bug (@marked) {
        $bugs{ $bug->{id} } = $bug;
    }

    my @cards = get_bugs_from_all_cards();
    
    fill_missing_bugs_info(\%bugs, @cards);

    return %bugs;
}

sub fill_missing_bugs_info {
  my ($bugs, @bugs) = @_;
  
  my @missing_bugs;
  
  foreach my $bugid (@bugs) {
    if ( not exists $bugs->{$bugid} ) {
      push @missing_bugs, $bugid;
    }
  }
  
  my $missing_bugs_ids = join ",", sort @bugs;
  
  my $req = 
    HTTP::Request->new( GET =>
"https://bugzilla.mozilla.org/rest/bug?token=$BUGZILLA_TOKEN&include_fields=id,status,whiteboard,summary,assigned_to&id=$missing_bugs_ids"
      );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }

    my $data = decode_json( $res->decoded_content );

    my @found_bugs = @{ $data->{bugs} };
  
    foreach my $bug (sort @found_bugs) {
      $bugs->{$bug->{id}} = $bug;
    }
  
    return;
}

sub get_marked_bugs {
    my $req =
      HTTP::Request->new( GET =>
"https://bugzilla.mozilla.org/rest/bug?token=$BUGZILLA_TOKEN&include_fields=id,status,whiteboard,summary,assigned_to&status_whiteboard_type=allwordssubstr&query_format=advanced&status_whiteboard=[kanban]"
      );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }

    my $data = decode_json( $res->decoded_content );

    my @bugs = @{ $data->{bugs} };

    return @bugs;
}

sub get_bugs_from_all_cards {

    my $req =
      HTTP::Request->new( POST =>
"http://kanbanize.com/index.php/api/kanbanize/get_all_tasks/boardid/$BOARD_ID/format/json"
      );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }

    my $cards = decode_json( $res->decoded_content );

    my @bugs;
    foreach my $card (@$cards) {
        my $extlink = $card->{extlink};    # XXX: Smarter parsing
        if ( $extlink =~ /(\d+)$/ ) {
            my $bugid = $1;
            push @bugs, $bugid;
        }
    }

    return @bugs;
}

sub sync_bug {
    my $bug = shift;

    #    print STDERR "Bugid: $bug->{id}\n" if $config->verbose;

    $total++;

    if ( not defined $bug ) {
        print STDERR "[$total/$count] No info for bug $bug->{id}\n";
        return;
    }

    if ( $bug->{error} ) {
        print STDERR
          "[$total/$count] No info for bug $bug->{id} (Private bug?)\n";
        return;
    }

    my $summary    = $bug->{summary};
    my $whiteboard = $bug->{whiteboard};

    my $card = parse_whiteboard($whiteboard);

    my $status = "";
    if ( not defined $card ) {
        $card = create_card($bug);

        if ( not $card ) {
            warn "Failed to create card for bug $bug->{id}";
            return;
        }

        update_whiteboard( $bug->{id}, $card->{taskid}, $whiteboard );

        $status .= "[card created]";
    }

    $card = retrieve_card( $card->{taskid} );

    my $cardid = $card->{taskid};

    my @changes = sync_card( $card, $bug );
    if (@changes) {
      $status .= " [synced]";
    }

    if ( $status ne "" or $config->verbose ) {
        printf STDERR
          "[%4d/%4d] Card %4d - Bug %8d - $summary $status\n", $total, $count, $cardid, $bug->{id};
    }
    
    if (@changes) {
      foreach my $change (@changes) {
        printf STDERR "[%4d/%4d] Card %4d - Bug %8d - $summary ** %s **\n", $total, $count, $cardid, $bug->{id}, $change;
      }
    }
}

sub retrieve_card {
    my $card_id = shift;

    my $req =
      HTTP::Request->new( POST =>
"http://kanbanize.com/index.php/api/kanbanize/get_task_details/boardid/$BOARD_ID/taskid/$card_id/format/json"
      );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }

    my $card = decode_json( $res->decoded_content );

    return $card;
}

sub sync_bugzilla {

}

sub sync_card {
    my ( $card, $bug ) = @_;

    my @updated;

    # Check Assignee
    my $bug_assigned  = $bug->{assigned_to};
    my $card_assigned = $card->{assignee};

    if (   defined $card_assigned
        && $card_assigned ne "None"
        && $bug_assigned =~ m/\@.*\.bugs$/ )
    {
        push @updated, "Update bug $bug->{id} assigned to $card_assigned";
        update_bug_assigned( $bug, $card_assigned );
    }
    elsif ($bug_assigned !~ m[^$card_assigned@]
        && $bug_assigned !~ m/\@.*\.bugs$/ )
    {
        push @updated, "Update card assigned to $bug_assigned";

        #print STDERR
        # "bug_asigned: $bug_assigned card_assigned: $card_assigned\n";
        update_card_assigned( $card, $bug_assigned );
    }

    #Check summary (XXX: Formatting assumption here)
    my $bug_summary  = "$bug->{id} - $bug->{summary}";
    my $card_summary = $card->{title};

    if ( $bug_summary ne $card_summary ) {
        update_card_summary( $card, $bug_summary );
        push @updated, "Updated card summary";
    }

    # Check status
    my $bug_status  = $bug->{status};
    my $card_status = $card->{columnname};

    # Close card on bug completion

    #warn "[$bug->{id}] bug: $bug_status card: $card_status" if $config->verbose;

    if ( ( $bug_status eq "RESOLVED" or $bug_status eq "VERIFIED" )
        and $card_status ne "Done" )
    {
        complete_card($card);
        push @updated, "Card completed";
    }

    # XXX: Should we close bug on card completion?
    if ( ( $bug_status ne "RESOLVED" and $bug_status ne "VERIFIED" )
        and $card_status eq "Done" )
    {
        if ( $bug_status eq "REOPENED" ) {
            reopen_card($card);
            #$updated++;
        }
        else {
            warn
"Bug $bug->{id} is not RESOLVED ($bug_status) but card $card->{taskid} says $card_status";
        }
    }

    # Check extlink
    my $bug_link = "https://bugzilla.mozilla.org/show_bug.cgi?id=$bug->{id}";

    if ( $card->{extlink} ne $bug_link ) {
        update_card_extlink( $card, $bug_link );
        push @updated, "Updated external link to bugzilla";
    }

    return @updated;
}

sub reopen_card {
    my $card = shift;

    warn
"[notimplemented] Should be reopening card $card->{taskid} and moving back to ready";

    return;
}

sub complete_card {
    my $card = shift;

    my $taskid = $card->{taskid};

    my $data = {
        boardid => $BOARD_ID,
        taskid  => $taskid,
        column  => 'Done',
    };

    my $req =
      HTTP::Request->new( POST =>
          "http://kanbanize.com/index.php/api/kanbanize/move_task/format/json"
      );

    $req->content( encode_json($data) );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }
}

sub update_card_extlink {
    my ( $card, $extlink ) = @_;

    my $taskid = $card->{taskid};

    my $data = {
        boardid => $BOARD_ID,
        taskid  => $taskid,
        extlink => $extlink,
    };

    my $req =
      HTTP::Request->new( POST =>
          "http://kanbanize.com/index.php/api/kanbanize/edit_task/format/json"
      );

    $req->content( encode_json($data) );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }
}

sub update_bug_assigned {
    my ( $bug, $assigned ) = @_;

    $assigned .= '@mozilla.com';

    my $bugid = $bug->{id};

    my $req =
      HTTP::Request->new(
        PUT => "https://bugzilla.mozilla.org/rest/bug/$bugid" );

    $req->content("assigned_to=$assigned&token=$BUGZILLA_TOKEN");

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }
}

sub update_card_summary {
    my ( $card, $bug_summary ) = @_;

    my $taskid = $card->{taskid};

    my $data = {
        boardid => $BOARD_ID,
        taskid  => $taskid,
        title   => $bug_summary,
    };

    my $req =
      HTTP::Request->new( POST =>
          "http://kanbanize.com/index.php/api/kanbanize/edit_task/format/json"
      );

    $req->content( encode_json($data) );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }
}

sub update_card_assigned {
    my ( $card, $bug_assigned ) = @_;

    my $taskid = $card->{taskid};
    ( my $assignee = $bug_assigned ) =~ s/\@.*//;

    my $req =
      HTTP::Request->new( POST =>
"http://kanbanize.com/index.php/api/kanbanize/edit_task/format/json/boardid/$BOARD_ID/taskid/$taskid/assignee/$assignee"
      );

    $req->content("[]");

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die $res->status_line;
    }

}

sub update_whiteboard {
    my ( $bugid, $cardid, $whiteboard ) = @_;

    my $req =
      HTTP::Request->new(
        PUT => "https://bugzilla.mozilla.org/rest/bug/$bugid" );

    if ( $whiteboard =~ m/\[kanban\]/ ) {
        $whiteboard =~ s/\[kanban\]//;
    }

    $whiteboard =
      "[kanban:https://kanbanize.com/ctrl_board/$BOARD_ID/$cardid] $whiteboard";

    $req->content("whiteboard=$whiteboard&token=$BUGZILLA_TOKEN");

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die $res->status_line;
    }

}

#XXX: https://bugzil.la/970457
sub create_card {
    my $bug = shift;

    my $data = {
        'title'   => "$bug->{id} - $bug->{summary}",
        'extlink' => "https://bugzilla.mozilla.org/show_bug.cgi?id=$bug->{id}",
        'boardid' => $BOARD_ID,
    };

    my $req =
      HTTP::Request->new( POST =>
"http://kanbanize.com/index.php/api/kanbanize/create_new_task/format/json"
      );

    $req->content( encode_json($data) );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        warn "can't create card:" . $res->status_line;
        die Dumper($res);
        return;
    }

    my $card = decode_json( $res->decoded_content );

    $card->{taskid} = $card->{id};

    move_card( $card, 'Pending Triage' );

    return $card;
}

sub move_card {
    my ( $card, $lane ) = @_;

    my $data = {
        boardid => $BOARD_ID,
        taskid  => $card->{taskid},
        column  => 'Backlog',
        lane    => $lane,
    };

    my $req =
      HTTP::Request->new( POST =>
          "http://kanbanize.com/index.php/api/kanbanize/move_task/format/json"
      );

    $req->content( encode_json($data) );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);
    }

}

sub get_bug_info {
    my $bugid = shift;
    my $data =
      get("https://bugzilla.mozilla.org/rest/bug/$bugid?token=$BUGZILLA_TOKEN");

    if ( not $data ) {
        warn "Failed getting Bug info for Bug $bugid from bugzilla\n";
        return { id => $bugid, error => "No Data" };
    }

    print STDERR "Retrieving info for Bug $bugid from bugzilla\n"
      if $config->verbose;

    $data = decode_json($data);

    return $data->{bugs}[0];
}

sub parse_whiteboard {
    my $whiteboard = shift;

    my $card;

    if ( $whiteboard =~
        m{\[kanban:https://kanbanize.com/ctrl_board/(\d+)/(\d+)\]} )
    {
        my $boardid = $1;
        my $cardid  = $2;

        $card = { taskid => $cardid };
    }

    return $card;
}

1;

=head1 SYNOPSIS

Kanbanize Bugzilla Sync Tool

=method new

This method does something experimental.

=method bar

This method returns a reason.

