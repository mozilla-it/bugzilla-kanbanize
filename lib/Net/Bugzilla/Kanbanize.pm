use strict;
use warnings;

package Net::Bugzilla::Kanbanize;

our $VERSION;

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

use Log::Log4perl ();

#XXX: https://bugzil.la/970457

my $log = Log::Log4perl::get_logger();

sub new {
    my ( $class, $config ) = @_;

    my $self = bless { config => $config }, $class;

    return $self;
}

=head2 version

prints current version to STDERR

=cut

sub version {
    return $VERSION || "git";
}

#XXX: Wrong, need to be instance variables

my $all_cards;

my $APIKEY;
my $BOARD_ID;
my $BUGZILLA_TOKEN;
my $KANBANIZE_INCOMING;
my $WHITEBOARD_TAG;
my @COMPONENTS;
my @PRODUCTS;
my %BUGMAIL_TO_KANBANID;
my %KANBANID_TO_BUGMAIL;

my $DRYRUN;
my $ua = LWP::UserAgent->new();

my $total;
my $count;
my $config;

sub run {
    my $self = shift;

    $config = $self->{config};

    $DRYRUN = $config->get('test');

    $APIKEY = ( $config->kanbanize_apikey || $ENV{KANBANIZE_APIKEY}) or die "Please configure an apikey";
    $BOARD_ID = ( $config->kanbanize_boardid || $ENV{KANBANIZE_BOARDID})
      or die "Please configure a kanbanize_boardid";
    $BUGZILLA_TOKEN = ( $config->bugzilla_token || $ENV{BUGZILLA_TOKEN})
      or die "Please configure a bugzilla_token";

    $KANBANIZE_INCOMING = $config->kanbanize_incoming;

    $WHITEBOARD_TAG = $config->tag || die "Missing whiteboard tag";

    @COMPONENTS = @{$config->component};
    @PRODUCTS = @{$config->product};

    %BUGMAIL_TO_KANBANID = %{$config->get("mail-map_bugmail")};
    %KANBANID_TO_BUGMAIL = reverse %BUGMAIL_TO_KANBANID;

    $ua->timeout(15);
    $ua->env_proxy;
    $ua->default_header( 'apikey' => $APIKEY );

    my %bugs;

    if (@ARGV) {
        fill_missing_bugs_info( "argv", \%bugs, @ARGV );
    }
    else {
        %bugs = get_bugs();
    }

    $count = scalar keys %bugs;

    $log->debug("Found a total of $count bugs");

    find_mislinked_bugs( \%bugs );
    find_mislinked_cards();

    $total = 0;

    while ( my ( $bugid, $bug ) = each %bugs ) {
        sync_bug($bug);
    }

    return 1;
}

sub find_mislinked_bugs {
    my($bugs) = @_;

    # whiteboard link -> [ bug, bug, ... ]
    my %whiteboards = ();

    while ( my( $bugid, $bug ) = each %{ $bugs } ) {
        # convert the bug into a card, if it exists.
        my $card = parse_whiteboard($bug->{whiteboard});
        if (defined $card) {
            # we only need the cardid for this check.
            my $cardid = $card->{cardid};
            if ($cardid) {
                # set it up to be an array, if it isn't one already.
                $whiteboards{$cardid} ||= [];
                # append the bug we found to the array.
                push(@{ $whiteboards{cardid} }, $bugid);
            }
        }
    }

    while ( my( $cardid, $bugids ) = each %whiteboards ) {
        if (@{ $bugids } > 1) {
            $log->warn("Card $cardid is referenced by whiteboards on multiple bugs: " . join(', ', @{ $bugids }));
        }
    }
}

sub find_card_for_bugid {
    my($bugid) = @_;

    for my $cardid (sort { $a <=> $b } keys %{ $all_cards }) {
        my $extlink = $all_cards->{$cardid}->{extlink};
        if (defined($extlink) && $extlink =~ /show_bug.cgi.*id=$bugid$/) {
            return $cardid;
        }
    }

    return undef;
}

sub find_mislinked_cards {
    # whiteboard link -> [ bug, bug, ... ]
    my %extlinks = ();

    while ( my( $cardid, $card ) = each %{ $all_cards } ) {
        my $extlink = $card->{extlink};
        if (defined($extlink) && $extlink =~ /show_bug.cgi.*id=(\d+)$/) {
            $extlinks{$1} ||= [];
            push(@{ $extlinks{$1} }, $cardid);
        }
    }

    while ( my( $bugid, $cardids ) = each %extlinks ) {
        if (@{ $cardids } > 1) {
            $log->warn("Bug $bugid is referenced by extlinks on multiple cards: " . join(', ', @{ $cardids }));
        }
    }
}

use URI;
use URI::QueryParam;

sub get_bug_history {
    my($bug) = @_;

    die "Invalid bug number" unless $bug =~ /^\d+$/;

    my $uri = URI->new("https://bugzilla.mozilla.org/rest/bug/$bug/history");
    $uri->query_param(token => $BUGZILLA_TOKEN);

    my $req = HTTP::Request->new( GET => $uri );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }

    my $data = decode_json( $res->decoded_content );

    my $results = [];

    # If this fails, we didn't get a bug history for whatever reason. Oh well.
    eval {
        for my $h (@{ $data->{'bugs'} }) {
            next unless $h->{'id'} eq $bug;
            if (@{ $h->{'history'} } > 0) {
                $results = $h->{'history'};
            }
        }
    };
    # XXX: Lazily assuming that no data and bad data are equivalent and okay here.
    #warn "$@" if $@;

    return $results;
}

sub get_bug_history_latest {
    my($bug, $field) = @_;

    die "Invalid bug number" unless $bug =~ /^\d+$/;
    die "Invalid field name" unless $field =~ /^\S+$/;

    my $history = get_bug_history($bug);

    my @timestamps = ();

    for my $entry (@{ $history }) {
        my $changes = $entry->{'changes'};
        my $found = 0;
        for my $change (@{$changes}) {
            next unless $change->{'field_name'} eq $field;
            $found = 1;
            last;
        }
        next unless $found;
        push @timestamps, $entry->{'when'};
    }

    # stop if we didn't find any history entries
    return '' unless @timestamps > 0;

    # sorts times of the format "2015-04-17T20:45:07Z" oldest to newest.
    @timestamps = sort @timestamps;

    # return the newest timestamp.
    return $timestamps[-1];
}

sub get_card_history_latest {
    my($card, $bugid) = @_;

    my $cardid = $card->{'taskid'};

    # The cache is populated by get_all_tasks, which doesn't have access to history data.
    # So we need to clear the cache and re-fetch the card, to get its history.
    delete ${ $all_cards }{$cardid};

    $card = retrieve_card($cardid, $bugid);

    my $history = $card->{'historydetails'};

    my @timestamps = ();

    for my $change (@{ $history }) {
        next unless $change->{'historyevent'} =~ /assignee/i;
        my $entrydate = $change->{'entrydate'};
        $entrydate =~ s/^(....-..-..) (..:..:..)$/$1T$2Z/;
        die "Unable to post-process entrydate from kanbanize" unless $entrydate =~ /^....-..-..T..:..:..Z$/;
        push @timestamps, $entrydate;
    }

    # stop if we didn't find any history entries
    return '' unless @timestamps > 0;

    # sorts times of the format "2015-04-17T20:45:07Z" oldest to newest.
    @timestamps = sort @timestamps;

    # return the newest timestamp.
    return $timestamps[-1];
}

sub get_bugs {
    my $uri = URI->new("https://bugzilla.mozilla.org/rest/bug");

    $uri->query_param(token => $BUGZILLA_TOKEN);
    $uri->query_param(include_fields => qw(id status whiteboard summary assigned_to));
    $uri->query_param(bug_status => qw(NEW UNCONFIRMED REOPENED ASSIGNED));
    $uri->query_param(product => @PRODUCTS);
    $uri->query_param(component => @COMPONENTS);

    my $req = HTTP::Request->new( GET => $uri );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }

    my $data = decode_json( $res->decoded_content );

    my %bugs;

    foreach my $bug ( @{ $data->{bugs} } ) {
        $bugs{ $bug->{id} } = $bug;
        $bugs{ $bug->{id} }{source} = "search";
    }

    my @marked = get_marked_bugs();

    foreach my $bug (@marked) {
        $bugs{ $bug->{id} } = $bug;
        $bugs{ $bug->{id} }{source} = "marked";
    }

    my @cced = get_cced_bugs();

    foreach my $bug (@cced) {
        $bugs{ $bug->{id} } = $bug;
        $bugs{ $bug->{id} }{source} = "cc";
    }

    my @cards = get_bugs_from_all_cards();

    fill_missing_bugs_info( "card", \%bugs, @cards );

    return %bugs;
}

sub fill_missing_bugs_info {
    my ( $source, $bugs, @bugs ) = @_;

    my @missing_bugs;

    foreach my $bugid (@bugs) {
        if ( not exists $bugs->{$bugid} ) {
            push @missing_bugs, $bugid;
        }
    }

    if (not @missing_bugs) {
      return;
    }

    my $missing_bugs_ids = join ",", sort @missing_bugs;

    my $url = "https://bugzilla.mozilla.org/rest/bug?token=$BUGZILLA_TOKEN&include_fields=id,status,whiteboard,summary,assigned_to&id=$missing_bugs_ids";

    my $req =
      HTTP::Request->new( GET => $url );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }

    my $data = decode_json( $res->decoded_content );

    my @found_bugs = @{ $data->{bugs} };

    foreach my $bug ( sort @found_bugs ) {
        $bugs->{ $bug->{id} } = $bug;
        $bugs->{ $bug->{id} }{source} = $source;
    }

    return;
}

# Also retrieve bugs we are cc'ed on.
sub get_cced_bugs {
    my $email = $config->bugzilla_id || $ENV{BUGZILLA_ID};

    my $req =
      HTTP::Request->new( GET =>
"https://bugzilla.mozilla.org/rest/bug?token=$BUGZILLA_TOKEN&include_fields=id,status,whiteboard,summary,assigned_to&bug_status=UNCONFIRMED&bug_status=NEW&bug_status=ASSIGNED&bug_status=REOPENED&emailcc1=1&emailtype1=exact&email1=$email"
      );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }

    my $data = decode_json( $res->decoded_content );

    my @bugs = @{ $data->{bugs} };

    return @bugs;
}

sub get_marked_bugs {
    my $uri = URI->new("https://bugzilla.mozilla.org/rest/bug");

    $uri->query_param(token => $BUGZILLA_TOKEN);
    $uri->query_param(include_fields => qw(id status whiteboard summary assigned_to));
    $uri->query_param(bug_status => qw(NEW UNCONFIRMED REOPENED ASSIGNED));
    $uri->query_param(product => @PRODUCTS);
    $uri->query_param(status_whiteboard_type => 'allwordssubstr');
    $uri->query_param(query_format => 'advanced');
    $uri->query_param(status_whiteboard => "[kanban:$WHITEBOARD_TAG]");

    my $req =
      HTTP::Request->new( GET => $uri );

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
"http://$WHITEBOARD_TAG.kanbanize.com/index.php/api/kanbanize/get_all_tasks/boardid/$BOARD_ID/format/json"
      );

    $req->header( "Content-Length" => "0" );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }

    my $cards = decode_json( $res->decoded_content );

    my @bugs;
    foreach my $card (@$cards) {
        # Skip archived cards
        if ($card->{columnname} eq 'Archive') {
            next;
        }
        $all_cards->{ $card->{taskid} } = $card;

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
        $log->warn("[$total/$count] No info for bug $bug->{id}");
        return;
    }

    if ( $bug->{error} ) {
        $log->warn("[$total/$count] No info for bug $bug->{id} (Private bug?)");
        return;
    }

    my $summary    = $bug->{summary};
    my $whiteboard = $bug->{whiteboard};

    my $card = parse_whiteboard($whiteboard);

    my @changes;
    if ( not defined $card ) {

        # For the source to be 'card' here, the bug has to have traversed a series of logic
        # steps to reach this point:
        #
        # - a card must have an extlink to the bug
        # - the bug must not be returned by the watched components search
        # - the bug must not have a cc: of the kanban watch user.
        #
        if ($bug->{source} eq 'card') {
            # If all three of these conditions are true, then we assume the bug is not meant
            # to be watched in Kanban, and refuse to populate the whiteboard.
            #
            # Improvements to this logic are pending, but not yet ready. See also:
            # https://github.com/mozilla-it/bugzilla-kanbanize/issues/9
            $log->warn("Bug $bug->{id} came from a card, but whiteboard is empty");
            return;
        }
        # Otherwise, the source is either 'argv' or 'cc' or 'search'. Onward to whiteboard.

        my $found_cardid = find_card_for_bugid($bug->{id});
        if ( defined $found_cardid ) {
            $card = retrieve_card($found_cardid, $bug->{id});

            $log->warn("Bug $bug->{id} already has a card $found_cardid, updating whiteboard");

            update_whiteboard($bug->{id}, $found_cardid, $whiteboard);

            push @changes, "[bug updated]";
        } else {
            $card = create_card($bug);

            if ( not $card ) {
                $log->warn("Failed to create card for bug $bug->{id}");
                return;
            }

            update_whiteboard( $bug->{id}, $card->{taskid}, $whiteboard );

            push @changes, "[card created]";
        }
    }

    my $new_card = retrieve_card( $card->{taskid}, $bug->{id} );

    # Referenced card missing
    if ( not $new_card ) {
      $log->warn(
        "Card $card->{taskid} referenced in bug $bug->{id} missing, clearing kanban whiteboard");
          clear_whiteboard( $bug->{id}, $card->{taskid}, $whiteboard );
      return;
    }

    $card = $new_card;

    my $cardid = $card->{taskid};

    push @changes, sync_card( $card, $bug );

    if ( $config->verbose ) {
        $log->debug(sprintf "[%4d/%4d] Card %4d - Bug %8d - [%s] %s ** %s **",
          $total, $count, $cardid, $bug->{id}, $bug->{source}, $summary, "in-sync");
    }

    if (@changes) {
        foreach my $change (@changes) {
            $log->info(sprintf "[%4d/%4d] Card %4d - Bug %8d - [%s] %s ** %s **",
              $total, $count, $cardid, $bug->{id}, $bug->{source}, $summary, $change);
        }
    }
}

sub retrieve_card {
    my $card_id = shift;
    my $bug_id = shift;

    if ( exists $all_cards->{$card_id} ) {
        return $all_cards->{$card_id};
    }

    my $params = {
        history => "yes",
        event   => "update",
    };

    my $req =
      HTTP::Request->new( POST =>
"http://$WHITEBOARD_TAG.kanbanize.com/index.php/api/kanbanize/get_task_details/boardid/$BOARD_ID/taskid/$card_id/format/json"
      );

    $req->content( encode_json($params) );

    my $res = $ua->request($req);

    my $data = decode_json( $res->decoded_content );

    if ( !$res->is_success ) {
        if ( $data->{Error} eq 'No such task or board.' ) {
            return;
        }
        #XXX: Might need to clear the whiteboard or sth...
        $log->warn("Can't find card $card_id for bug $bug_id");
        return;
        #die Dumper( $data, $res );    #$res->status_line;
    }

    $all_cards->{$card_id} = $data;

    return $all_cards->{$card_id};
}

sub sync_bugzilla {

}

sub sync_card {
    my ( $card, $bug ) = @_;

    my @updated;

    # Check Assignee
    my $bug_assigned  = $bug->{assigned_to};
    my $card_assigned = $card->{assignee};

    # Need to convert assigned to canonical version, bugmail

    my $card_assigned_bugmail = kanbanid_to_bugmail($card->{assignee});

    if ( not defined $card_assigned ) {
        die Dumper( $bug, $card );
    }

    # Set this to 'update' if the assignees are out of sync.
    # We'll decide which way to sync using history timestamps.
    my($assignee_task) = 'none';

    if (   defined $card_assigned
        && $card_assigned ne "None"
        && $card_assigned ne 'nobody'
        && !assigned_bugzilla_email($bug_assigned)
    )
    {
        # The card is assigned, the bug is not.
        # Perhaps we need to update the bug to match the card.
        $assignee_task = 'update';
    }
    elsif ( ($bug_assigned ne $card_assigned_bugmail)
        && assigned_bugzilla_email($bug_assigned) )
    {
        my $kanbanid = bugmail_to_kanbanid($bug_assigned);
        my $bugmail = kanbanid_to_bugmail($kanbanid);

        if ($bug_assigned ne $bugmail) {
            $log->warn("[bug $bug->{id}] Bugmail user $bug_assigned not mapped to a kanban user, skipping assigned checks");
        }
        else {
            # The bug is assigned, the card doesn't match.
            # Perhaps we need to update the card to match the bug.
            $assignee_task = 'update';
        }
    }

    # Do we need to update assignees?
    if ($assignee_task eq 'update') {
        # Find out when the card and the bug were last updated.
        my $time_bug = get_bug_history_latest($bug->{id}, 'assigned_to');
        my $time_card = get_card_history_latest($card, $bug->{id});

        if ($time_bug eq $time_card) {
            # This is incredibly unlikely to occur, but if it does, we'll assume the bug is correct.
            $assignee_task = 'update_bug';
        } else {
            # We have two different times. Figure out which one is newer and use it.
            my @times = ($time_bug, $time_card);
            @times = sort @times;

            if ($times[-1] eq $time_bug) {
                # The bug was updated more recently. Update the card to reflect the bug.
                $assignee_task = 'update_card';

                push @updated, "Update card assigned to $bug_assigned";
                #print STDERR
                # "bug_asigned: $bug_assigned card_assigned: $card_assigned\n";
                update_card_assigned( $card, $bug_assigned );
            } else {
                # The card was updated more recently. Update the bug to reflect the card.
                $assignee_task = 'update_bug';

                # Was the card assigned to someone, or unassigned to nobody?
                if ($card_assigned eq 'None' || $card_assigned eq 'nobody') {
                    # It was unassigned. Reset the bug to its default assignee.
                    my $error = reset_bug_assigned($bug);

                    if (!$error) {
                        $error = "**FAILED**";
                    }

                    push @updated, "Reset bug $bug->{id} assigned $error";
                } else {
                    # It was assigned. Update the bug to reflect this.
                    my $error = update_bug_assigned($bug, $card_assigned);

                    if (!$error) {
                        $error = "**FAILED**";
                    }

                    push @updated, "Update bug $bug->{id} assigned to $card_assigned $error";
                }
            }
        }

        #$log->warn(sprintf("bug << %s >> card << %s >> task << %s >>", $bug->{id}, $card->{taskid}, $assignee_task));
    }

    #Check summary (XXX: Formatting assumption here)
    my $bug_summary  = "$bug->{id} - $bug->{summary}";
    my $card_summary = $card->{title};

    if ( $bug_summary ne $card_summary ) {
        update_card_summary( $card, $bug_summary );
        push @updated, "Updated card summary ('$bug_summary' vs '$card_summary')";
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
            # If it's in webops, close it, otherwise, skip it ?
            $log->warn("Bug $bug->{id} is not RESOLVED ($bug_status) but card $card->{taskid} says $card_status");
        }
    }

    # Check extlink
    my $bug_link = "https://bugzilla.mozilla.org/show_bug.cgi?id=$bug->{id}";

    if ( $card->{extlink} ne $bug_link ) {
        update_card_extlink( $card, $bug_link );
        push @updated, "Updated external link to bugzilla ( $card->{extlink} => $bug_link)";
    }

    return @updated;
}

sub reopen_card {
    my $card = shift;

    $log->warn("[notimplemented] Should be reopening card $card->{taskid} and moving back to ready");

    return;
}

sub unblock_card {
    my $card = shift;

    my $taskid = $card->{taskid};

    my $data = {
        boardid => $BOARD_ID,
        taskid  => $taskid,
        event   => 'unblock',
    };

    if ($DRYRUN) {
      $log->debug("unblock card");
      return;
    }

    my $req =
      HTTP::Request->new( POST =>
          "http://$WHITEBOARD_TAG.kanbanize.com/index.php/api/kanbanize/block_task/format/json"
      );

    $req->content( encode_json($data) );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        my $content = $res->content;
        my $status  = $res->status_line;
        $log->warn("Kanban API request failed while unblocking card #$taskid: $status <<< $content >>>");
    }
}

sub complete_card {
    my $card = shift;

    if ($card->{blocked} == 1) {
        # First, unblock the card, so that we can move it.
        unblock_card($card);
    }

    my $taskid = $card->{taskid};

    my $data = {
        boardid => $BOARD_ID,
        taskid  => $taskid,
        column  => 'Done',
    };

    if ($DRYRUN) {
      $log->debug("complete card");
      return;
    }

    my $req =
      HTTP::Request->new( POST =>
          "http://$WHITEBOARD_TAG.kanbanize.com/index.php/api/kanbanize/move_task/format/json"
      );

    $req->content( encode_json($data) );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        my $content = $res->content;
        my $status  = $res->status_line;
        $log->warn("Kanban API request failed while closing card #$taskid: $status <<< $content >>>");
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

    if ($DRYRUN) {
      $log->debug("update_card_extlink");
      return;
    }

    my $req =
      HTTP::Request->new( POST =>
          "http://$WHITEBOARD_TAG.kanbanize.com/index.php/api/kanbanize/edit_task/format/json"
      );

    $req->content( encode_json($data) );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die Dumper($res);    #$res->status_line;
    }
}

sub reset_bug_assigned {
    my ( $bug ) = @_;

    my $bugid = $bug->{id};

    if ($DRYRUN) {
      $log->debug( "Resetting bug assigned to" );
      return;
    }

    my $req =
      HTTP::Request->new(
        PUT => "https://bugzilla.mozilla.org/rest/bug/$bugid" );

    $req->content("reset_assigned_to=true&token=$BUGZILLA_TOKEN");

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        my $ct = $res->content_type;

        if ($ct eq 'application/json') {
            my $error;

            eval {
                $error = decode_json($res->content);
            };

            if (ref($error) eq 'HASH') {
                my $code = $error->{code};
                my $error_message = $error->{message};
                $log->error("Error no=$code talking to bugzilla: $error_message");
                return;
            }
        }


        die Dumper($res);    #$res->status_line;
    }

    return $res->is_success;
}

sub update_bug_assigned {
    my ( $bug, $assigned ) = @_;

    $assigned = kanbanid_to_bugmail($assigned);

    my $bugid = $bug->{id};

    if ($DRYRUN) {
      $log->debug( "Updating bug assigned to $assigned" );
      return;
    }

    my $req =
      HTTP::Request->new(
        PUT => "https://bugzilla.mozilla.org/rest/bug/$bugid" );

    $req->content("assigned_to=$assigned&token=$BUGZILLA_TOKEN");

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        my $ct = $res->content_type;

        if ($ct eq 'application/json') {
            my $error;

            eval {
                $error = decode_json($res->content);
            };

            if (ref($error) eq 'HASH') {
                my $code = $error->{code};
                my $error_message = $error->{message};
                $log->error("Error no=$code talking to bugzilla: $error_message");
                return;
            }
        }


        die Dumper($res);    #$res->status_line;
    }

    return $res->is_success;
}

sub update_card_summary {
    my ( $card, $bug_summary ) = @_;

    my $taskid = $card->{taskid};



    my $data = {
        boardid => $BOARD_ID,
        taskid  => $taskid,
        title   => api_encode_title($bug_summary),
    };

    if($DRYRUN) {
      $log->debug("Update card summary : $bug_summary");
      return;
    }

    my $req =
      HTTP::Request->new( POST =>
          "http://$WHITEBOARD_TAG.kanbanize.com/index.php/api/kanbanize/edit_task/format/json"
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

    my $assignee = bugmail_to_kanbanid($bug_assigned);

    if ($DRYRUN) {
      $log->debug("Update card assigned: $assignee");
      return;
    }

    $assignee = URI::Escape::uri_escape($assignee);

    my $req =
      HTTP::Request->new( POST =>
"http://$WHITEBOARD_TAG.kanbanize.com/index.php/api/kanbanize/edit_task/format/json/boardid/$BOARD_ID/taskid/$taskid/assignee/$assignee"
      );

    $req->content("[]");

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        warn Dumper($res);
        die $res->status_line;
    }
}

sub update_whiteboard {
    my ( $bugid, $cardid, $whiteboard ) = @_;

    if ($DRYRUN) {
      $log->debug( "Updating whiteboard" );
      return;
    }

    my $req =
      HTTP::Request->new(
        PUT => "https://bugzilla.mozilla.org/rest/bug/$bugid" );

    # Clear kanban request
    if ( $whiteboard =~ m/\[kanban:$WHITEBOARD_TAG\]/ ) {
        $whiteboard =~ s/\[kanban:$WHITEBOARD_TAG\]//;
    }

    # Clear unqualified whiteboard
    if ( $whiteboard =~ m{\[kanban:https://kanbanize.com/ctrl_board/\d+/\d+\]} ) {
        $whiteboard =~ s{\[kanban:https://kanbanize.com/ctrl_board/\d+/\d+\]}{};
    }

    # Clear old qualified whiteboards

    if ($whiteboard =~ m{kanban:$WHITEBOARD_TAG:https://kanbanize.com/ctrl_board/\d+/\d+} ) {
        $whiteboard =~ s{kanban:$WHITEBOARD_TAG:https://kanbanize.com/ctrl_board/\d+/\d+}{};
    }



    $whiteboard =
      "[kanban:https://$WHITEBOARD_TAG.kanbanize.com/ctrl_board/$BOARD_ID/$cardid] $whiteboard";

    $req->content("whiteboard=$whiteboard&token=$BUGZILLA_TOKEN");

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die $res->status_line;
    }

}

sub clear_whiteboard {
    my ( $bugid, $cardid, $whiteboard ) = @_;

    if ($DRYRUN) {
      $log->debug( "Clearing whiteboard" );
      return;
    }

    my $req =
      HTTP::Request->new(
        PUT => "https://bugzilla.mozilla.org/rest/bug/$bugid" );

    $whiteboard =~ s/\s?\[kanban:[^]]+\]\s?//g;

    $req->content("whiteboard=$whiteboard&token=$BUGZILLA_TOKEN");

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        die $res->status_line;
    }

}

#XXX: https://bugzil.la/970457
sub create_card {
    my $bug = shift;

    if ($DRYRUN) {
      $log->debug( "Creating card" );
      return { taskid => 0, id => 0, };
    }

    my $data = {
        'title'   => api_encode_title("$bug->{id} - $bug->{summary}"),
        'extlink' => "https://bugzilla.mozilla.org/show_bug.cgi?id=$bug->{id}",
        'boardid' => $BOARD_ID,
    };

    my $req =
      HTTP::Request->new( POST =>
"http://$WHITEBOARD_TAG.kanbanize.com/index.php/api/kanbanize/create_new_task/format/json"
      );

    $req->content( encode_json($data) );

    my $res = $ua->request($req);

    if ( !$res->is_success ) {
        $log->error( "can't create card:" . $res->status_line );
        die Dumper($res);
        return;
    }

    my $card = decode_json( $res->decoded_content );

    $card->{taskid} = $card->{id};

    move_card( $card, $KANBANIZE_INCOMING );

    return $card;
}

sub move_card {
    my ( $card, $lane ) = @_;

    if ($DRYRUN) {
      $log->debug( "Moving card to $lane" );
      return;
    }

    my $data = {
        boardid => $BOARD_ID,
        taskid  => $card->{taskid},
        column  => 'Backlog',
        lane    => $lane,
    };

    my $req =
      HTTP::Request->new( POST =>
          "http://$WHITEBOARD_TAG.kanbanize.com/index.php/api/kanbanize/move_task/format/json"
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
        $log->error( "Failed getting Bug info for Bug $bugid from bugzilla" );
        return { id => $bugid, error => "No Data" };
    }

    $log->debug("Retrieving info for Bug $bugid from bugzilla");

    $data = decode_json($data);

    return $data->{bugs}[0];
}

sub parse_whiteboard {
    my $whiteboard = shift;

    my $card;

    #XXX: Unqualified kanmban tag, need to handle...
    if ( $whiteboard =~
        m{\[kanban:https://kanbanize.com/ctrl_board/(\d+)/(\d+)\]} )
    {
        my $boardid = $1;
        my $cardid  = $2;

        if ($BOARD_ID ne $boardid) {
          $log->warn( "Found a card from a mismatched board:$boardid" );
          return undef;
        }

        $card = { taskid => $cardid };
    }
    elsif ( $whiteboard =~
        m{\[kanban:https://$WHITEBOARD_TAG.kanbanize.com/ctrl_board/(\d+)/(\d+)\]} )
    {
        my $boardid = $1;
        my $cardid  = $2;

        if ($BOARD_ID ne $boardid) {
          $log->warn( "Found a card from a mismatched board:$boardid" );
          return undef;
        }

        $card = { taskid => $cardid };
    }
    elsif ( $whiteboard =~ m{\[kanban:ignore\]} ) {
      $log->info( "Should ignore this card!" );
      $card = {
        ignore => 1,
        taskid => 0 
      };
    }

    return $card;
}

sub assigned_bugzilla_email {
  my $mail = shift;

  my $assigned = 1;

  if ($mail =~ m/\@.*\.bugs$/) {
    $assigned = 0;
  }

  if ($mail eq 'nobody@mozilla.org') {
    $assigned = 0;
  }

  return $assigned;
}

sub bugmail_to_kanbanid {
  my $bugmail = shift;
  my $kanbanid;

  if (exists $BUGMAIL_TO_KANBANID{$bugmail}) {
    $kanbanid = $BUGMAIL_TO_KANBANID{$bugmail};
  }
  elsif ($bugmail =~ /\@mozilla.com$/) {
    ( $kanbanid = $bugmail ) =~ s/\@.*//;
  }
  else {
    $kanbanid = 'None';

    $log->debug("Unable to convert bugmail $bugmail to a valid kanbanid, resorting to 'None'.");
  }

  return $kanbanid;
}


sub kanbanid_to_bugmail {
  my $kanbanid = shift;
  my $bugmail;

  if (exists $KANBANID_TO_BUGMAIL{$kanbanid}) {
    $bugmail = $KANBANID_TO_BUGMAIL{$kanbanid}
  }
  else {
    $bugmail = "$kanbanid\@mozilla.com";
  }

  return $bugmail;
}

sub api_encode_title ($) {
    my $title = shift;
    # Kanbanize requires a backslash to be present within the title value.
    $title =~ s/\"/\\\"/g;
    # Kanbanize requires URI escaping of only the title, but no other elements.
    $title = URI::Escape::uri_escape($title);
    return $title;
}

1;

=head1 SYNOPSIS

Kanbanize Bugzilla Sync Tool

=head1 METHODS

=head2 new

This method does something experimental.

=head2 version

This method returns a reason.

