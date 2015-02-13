package FixMyStreet::Roles::Extra;
use Moose::Role;

=head1 NAME

FixMyStreet::Roles::Extra - role for accessing {extra} field

=head1 SYNOPSIS

This is to applied to a DB class like Problem or Contacts that has a rich {extra} field:

    use Moose;
    with 'FixMyStreet::Roles::Extra';

(NB: there is actually a little more boilerplate, because DBIC doesn't actually
inherit from Moose, see ::Problem for an example.)

Then:

    $contact->set_extra_fields($c,
        { name => 'pothole_size', ... },
        { name => 'pothole_shape, ... } );
    my $metas = $contact->get_extra_fields($c);

And

    # e.g. for sites like Zurich (but handled gracefully otherwise)
    $problem->set_extra_metadata($c, overdue => 1 );
    if ($problem->get_extra_metadata($c, 'overdue')) { ... }

=head1 METHODS

=head2 set_extra_metadata

    $problem->set_extra_metadata($c, overdue => 1);

=cut

sub set_extra_metadata {
    my ($self, $c, $key, $value) = @_;
    my $extra = $self->get_extra($c);

    return unless ref $extra eq 'HASH';
    $extra->{$key} = $value;
    return $self->dirty_extra;
};

=head2 unset_extra_metadata

    $contact->unset_extra_metadata($c, 'photo_required');

=cut

sub unset_extra_metadata {
    my ($self, $c, $key) = @_;
    my $extra = $self->get_extra($c);

    return unless ref $extra eq 'HASH';
    return 1 unless exists $extra->{$key};
    delete $extra->{$key};
    return $self->dirty_extra;
};

=head2 set_extra_metadata

    my $overdue = $problem->get_extra_metadata($c, 'overdue');

=cut

sub get_extra_metadata {
    my ($self, $c, $key) = @_;
    my $extra = $self->get_extra($c);

    return unless ref $extra eq 'HASH';
    return $extra->{$key};
};

=head2 get_extra_metadata_as_hashref

    my $hashref = $contact->get_extra_metadata_as_hashref($c);

=cut

sub get_extra_metadata_as_hashref {
    my ($self, $c) = @_;
    my $extra = $self->get_extra($c);

    return {} unless ref $extra eq 'HASH';
    my %extra = %$extra;
    delete $extra{_fields};
    return \%extra;
}

=head2 get_extra_fields

    my $metas = $problem->get_extra_fields($c);

=cut

sub get_extra_fields {
    my ($self, $c) = @_;
    my $extra = $self->get_extra($c);

    return $extra if ref $extra eq 'ARRAY';
    return $extra->{_fields} ||= do {
        $self->dirty_extra;
        [];
    };
}

=head2 set_extra_fields

    $problem->get_extra_fields($c, { ... }, { ... } );

=cut

sub set_extra_fields {
    my ($self, $c, @fields) = @_;
    my $extra = $self->get_extra($c);

    if (ref $extra eq 'ARRAY') {
        # replace extra entirely with provided fields
        $self->extra(\@fields);
    }
    else {
        $extra->{_fields} = \@fields;
    }

    $self->dirty_extra;
}

=head1 HELPER METHODS

For internal use mostly.

=head2 dirty_extra

Set the extra field as dirty.  (e.g. signalling that the DB object should be
updated).

=cut

sub dirty_extra {
    my $self = shift;
    $self->make_column_dirty('extra');
    return 1;
}

=head2 get_extra

Get the extra data.  If this is not set, then returns a {} or [] reference
I<as appropriate>, e.g. depending on the Cobrand's expected layout.  This
worrying about whether we should return a hash or array reference is the reason
that we have to pass $c to Every Single Method (i.e. so that we can get access
to C<$c-E<gt>cobrand>.

(This is a bit of a wart, can we do better?)

=cut

sub get_extra {
    my ($self, $c) = @_;
    return $self->extra || do {
        my $extra = $c->cobrand->default_extra_layout;
        $self->extra($extra);
        $self->dirty_extra;
        return $extra;
    };
}

1;
