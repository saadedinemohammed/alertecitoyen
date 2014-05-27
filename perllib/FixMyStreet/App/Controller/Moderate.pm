package FixMyStreet::App::Controller::Moderate;

use Moose;
use namespace::autoclean;
use Algorithm::Diff;
BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

FixMyStreet::App::Controller::Moderate - process a moderation event

=head1 DESCRIPTION

The intent of this is that council users will be able to moderate reports
by themselves, but without requiring access to the full admin panel.

From a given report page, an authenticated user will be able to press
the "moderate" button on report and any updates to bring up a form with
data to change.

(Authentication requires:

  - user to be from_body
  - user to have a "moderate" record in user_body_permissions (there is
        currently no admin interface for this.  Should be added, but
        while we're trialing this, it's a simple case of adding a DB record
        manually)

The original data of the report is stored in moderation_original_data, so
that it can be reverted/consulted if required.  All moderation events are
stored in moderation_log.  (NB: In future, this could be combined with
admin_log).

=head1 SEE ALSO

DB tables:

    ModerationLog
    ModerationOriginalData
    UserBodyPermissions

=cut

sub moderate : Chained('/') : PathPart('moderate') : CaptureArgs(0) { }

sub report : Chained('moderate') : PathPart('report') : CaptureArgs(1) {
    my ($self, $c, $id) = @_;
    my $problem = $c->model('DB::Problem')->find($id);

    my $report_uri = $c->cobrand->base_url_for_report( $problem ) . $problem->url;
    $c->res->redirect( $report_uri ); # this will be the final endpoint after all processing...

    # ... and immediately, if the user isn't authorized
    $c->detach unless $c->user_exists;
    $c->detach unless $c->user->has_permission_to(moderate => $problem->bodies_str);

    my $original = $problem->find_or_new_related( moderation_original_data => {
        title => $problem->title,
        detail => $problem->detail,
        photo => $problem->photo,
        anonymous => $problem->anonymous,
    });
    $c->stash->{problem} = $problem;
    $c->stash->{problem_original} = $original;
    $c->stash->{moderation_reason} = $c->req->param('moderation_reason') // '';
}

sub moderate_report : Chained('report') : PathPart('') : Args(0) {
    my ($self, $c) = @_;

    $c->forward('report_moderate_title');
    $c->forward('report_moderate_detail');
    $c->forward('report_moderate_anon');
    $c->forward('report_moderate_photo');
}

sub report_moderate_title : Private {
    my ( $self, $c ) = @_;

    my $problem = $c->stash->{problem} or die;
    my $original = $c->stash->{problem_original};

    my $old_title = $problem->title;
    my $original_title = $original->title;

    my $title = $c->req->param('problem_revert_title') ?
        $original_title
        : $self->diff($original_title, $c->req->param('problem_title'));

    if ($title ne $old_title) {
        $c->model('DB::ModerationLog')->create({
            user => $c->user->obj,
            problem => $problem,
            moderation_object => 'problem',
            moderation_type => 'title',
            reason => $c->stash->{'moderation_reason'},
        });
        $original->insert unless $original->in_storage;
        $problem->update({ title => $title });
    }
}

sub report_moderate_detail : Private {
    my ( $self, $c ) = @_;

    my $problem = $c->stash->{problem} or die;
    my $original = $c->stash->{problem_original};

    my $old_detail = $problem->detail;
    my $original_detail = $original->detail;
    my $detail = $c->req->param('problem_revert_detail') ?
        $original_detail
        : $self->diff($original_detail, $c->req->param('problem_detail'));

    if ($detail ne $old_detail) {
        $c->model('DB::ModerationLog')->create({
            user => $c->user->obj,
            problem => $problem,
            moderation_object => 'problem',
            moderation_type => 'detail',
            reason => $c->stash->{'moderation_reason'},
        });

        $original->insert unless $original->in_storage;

        $problem->update({ detail => $detail });
    }
}

sub report_moderate_anon : Private {
    my ( $self, $c ) = @_;

    my $problem = $c->stash->{problem} or die;
    my $original = $c->stash->{problem_original};

    my $show_user = $c->req->param('problem_show_name') ? 1 : 0;
    my $anonymous = $show_user ? 0 : 1;
    my $old_anonymous = $problem->anonymous ? 1 : 0;

    if ($anonymous != $old_anonymous) {
        $c->model('DB::ModerationLog')->create({
            user => $c->user->obj,
            problem => $problem,
            moderation_object => 'problem',
            moderation_type => 'anonymous',
            reason => $c->stash->{'moderation_reason'},
        });

        $original->insert unless $original->in_storage;
        $problem->update({ anonymous => $anonymous });
    }
}

sub report_moderate_photo : Private {
    my ( $self, $c ) = @_;

    my $problem = $c->stash->{problem} or die;
    my $original = $c->stash->{problem_original};

    return unless $original->photo;

    my $show_photo = $c->req->param('problem_show_photo') ? 1 : 0;
    my $old_show_photo = $problem->photo ? 1 : 0;

    if ($show_photo != $old_show_photo) {
        $c->model('DB::ModerationLog')->create({
            user => $c->user->obj,
            problem => $problem,
            moderation_object => 'problem',
            moderation_type => 'photo',
            reason => $c->stash->{'moderation_reason'},
        });

        $original->insert unless $original->in_storage;
        $problem->update({ photo => $show_photo ? $original->photo : undef });
    }
}

sub update : Chained('report') : PathPart('update') : CaptureArgs(1) {
    my ($self, $c, $id) = @_;
    my $comment = $c->stash->{problem}->comments->find($id);

    my $original = $comment->find_or_new_related( moderation_original_data => {
        detail => $comment->text,
        photo => $comment->photo,
        anonymous => $comment->anonymous,
    });
    $c->stash->{comment} = $comment;
    $c->stash->{comment_original} = $original;
}

sub moderate_update : Chained('update') : PathPart('') : Args(0) {
    my ($self, $c) = @_;

    $c->forward('update_moderate_detail');
    $c->forward('update_moderate_anon');
    $c->forward('update_moderate_photo');
}

sub update_moderate_detail : Private {
    my ( $self, $c ) = @_;

    my $problem = $c->stash->{problem} or die;
    my $comment = $c->stash->{comment} or die;
    my $original = $c->stash->{comment_original};

    my $old_detail = $comment->text;
    my $original_detail = $original->detail;
    my $detail = $c->req->param('update_revert_detail') ?
        $original_detail
        : $self->diff($original_detail, $c->req->param('update_detail'));

    if ($detail ne $old_detail) {
        $c->model('DB::ModerationLog')->create({
            user => $c->user->obj,
            problem => $problem,
            comment => $comment,
            moderation_object => 'comment',
            moderation_type => 'detail',
            reason => $c->stash->{'moderation_reason'},
        });

        $original->insert unless $original->in_storage;

        $comment->update({ text => $detail });
    }
}

sub update_moderate_anon : Private {
    my ( $self, $c ) = @_;

    my $problem = $c->stash->{problem} or die;
    my $comment = $c->stash->{comment} or die;
    my $original = $c->stash->{comment_original};

    my $show_user = $c->req->param('update_show_name') ? 1 : 0;
    my $anonymous = $show_user ? 0 : 1;
    my $old_anonymous = $comment->anonymous ? 1 : 0;

    if ($anonymous != $old_anonymous) {
        $c->model('DB::ModerationLog')->create({
            user => $c->user->obj,
            problem => $problem,
            comment => $comment,
            moderation_object => 'comment',
            moderation_type => 'anonymous',
            reason => $c->stash->{'moderation_reason'},
        });

        $original->insert unless $original->in_storage;
        $comment->update({ anonymous => $anonymous });
    }
}

sub update_moderate_photo : Private {
    my ( $self, $c ) = @_;

    my $problem = $c->stash->{problem} or die;
    my $comment = $c->stash->{comment} or die;
    my $original = $c->stash->{comment_original};

    return unless $original->photo;

    my $show_photo = $c->req->param('update_show_photo') ? 1 : 0;
    my $old_show_photo = $comment->photo ? 1 : 0;

    if ($show_photo != $old_show_photo) {
        $c->model('DB::ModerationLog')->create({
            user => $c->user->obj,
            problem => $problem,
            comment => $comment,
            moderation_object => 'comment',
            moderation_type => 'photo',
            reason => $c->stash->{'moderation_reason'},
        });

        $original->insert unless $original->in_storage;
        $comment->update({ photo => $show_photo ? $original->photo : undef });
    }
}

sub return_text : Private {
    my ($self, $c, $text) = @_;

    $c->res->content_type('text/plain; charset=utf-8');
    $c->res->body( $text // '' );
}

sub diff {
    my ($self, $old, $new) = @_;

    $new =~s/\[redacted\]//g;
    $new =~s/\[\.{3}\]//g;

    my $diff = Algorithm::Diff->new( [ split //, $old ], [ split //, $new ] );
    my $string;
    while ($diff->Next) {
        my $d = $diff->Diff;
        if ($d & 1) {
            my $deleted = join '', $diff->Items(1);
            unless ($deleted =~/^\s*$/) {
                $string .= ' ' if $deleted =~/^ /;
                my $letters = ($deleted=~s/\W//r);
                $string .= length $letters > 5 ? "[redacted]" : '[...]';
                $string .= ' ' if $deleted =~/ $/;
            }
        }
        $string .= join '', $diff->Items(2);
    }
    return $string;
}


__PACKAGE__->meta->make_immutable;

1;
