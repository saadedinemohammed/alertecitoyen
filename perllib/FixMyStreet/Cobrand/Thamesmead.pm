package FixMyStreet::Cobrand::Thamesmead;
use parent 'FixMyStreet::Cobrand::UK';

use strict;
use warnings;

sub council_area { return 'Thamesmead'; }
sub council_name { return 'Thamesmead'; }
sub council_url { return 'thamesmead'; }

sub admin_user_domain { ( 'thamesmeadnow.org.uk', 'peabody.org.uk' ) }

sub updates_disallowed {
    my $self = shift;
    my $problem = shift;
    my $c = $self->{c};

    my $staff = $c->user_exists && $c->user->from_body && $c->user->from_body->name eq $self->council_name;
    my $superuser = $c->user_exists && $c->user->is_superuser;
    my $reporter = $c->user_exists && $c->user->id == $problem->user->id;
    my $closed_to_updates = $self->SUPER::updates_disallowed($problem);

    if (($staff || $superuser || $reporter) && !$closed_to_updates) {
        return;
    } else {
        return 1;
    }
}

sub admin_allow_user {
    my ( $self, $user ) = @_;
    return 1 if $user->is_superuser;
    return undef unless defined $user->from_body;
    return $user->from_body->name eq 'Thamesmead';
}

sub cut_off_date { '2022-04-25' }
sub problems_restriction { FixMyStreet::Cobrand::UKCouncils::problems_restriction($_[0], $_[1]) }
sub problems_on_map_restriction { $_[0]->problems_restriction($_[1]) }
sub problems_sql_restriction { FixMyStreet::Cobrand::UKCouncils::problems_sql_restriction($_[0], $_[1]) }
sub users_restriction { FixMyStreet::Cobrand::UKCouncils::users_restriction($_[0], $_[1]) }
sub updates_restriction { FixMyStreet::Cobrand::UKCouncils::updates_restriction($_[0], $_[1]) }
sub site_key { FixMyStreet::Cobrand::UKCouncils::site_key($_[0], $_[1]) }
sub all_reports_single_body { FixMyStreet::Cobrand::UKCouncils::all_reports_single_body($_[0], $_[1]) }

sub base_url { FixMyStreet::Cobrand::UKCouncils::base_url($_[0]) }

sub contact_email {
    my $self = shift;
    return $self->feature('contact_email');
};

sub default_map_zoom { 6 }

sub enter_postcode_text {
    my ( $self ) = @_;
    return _("Enter the road name, postcode or the area closest to the problem");
}

sub example_places {
    return [ 'Glendale Way', 'Manorway Green' ];
}

sub munge_report_new_bodies {
    my ($self, $bodies) = @_;

    %$bodies = map { $_->id => $_ } grep { $_->name eq 'Thamesmead' } values %$bodies;
}

sub privacy_policy_url {
    'https://www.thamesmeadnow.org.uk/terms-and-conditions/privacy-statement/'
}

sub get_geocoder { 'OSM' }

sub disambiguate_location {
    my $self    = shift;
    my $string  = shift;

    my $results = {
        %{ $self->SUPER::disambiguate_location() },
        bounds => [ 51.49, 0.075, 51.514, 0.155 ],
        string => $string,
    };

    return $results;
}

sub geocoder_munge_results {
    my $self = shift;
    my ($result) = @_;
    if ($result->{display_name} !~ /Greenwich|Bexley|Thamesmead/) {
        $result->{display_name} = '';
    }

}

my @categories = qw( hardsurfaces grass water treegroups planting );
my %category_titles = (
    hardsurfaces => 'Hard surfaces/paths/road (Peabody)',
    grass => 'Grass and grass areas (Peabody)',
    water => 'Water areas (Peabody)',
    treegroups => 'Trees (Peabody)',
    planting => 'Planters and flower beds (Peabody)',
);
my %cat_idx = map { $categories[$_] => $_ } 0..$#categories;

sub area_type_for_point {
    my ( $self ) = @_;

    my ($x, $y) = Utils::convert_latlon_to_en(
        $self->{c}->stash->{latitude},
        $self->{c}->stash->{longitude},
        'G'
    );

    my $filter = "(<Filter><Contains><PropertyName>Extent</PropertyName><gml:Point><gml:coordinates>$x,$y</gml:coordinates></gml:Point></Contains></Filter>)";
    my $cfg = {
        url => "https://tilma.mysociety.org/mapserver/thamesmead",
        srsname => "urn:ogc:def:crs:EPSG::27700",
        typename => join(',', @categories),
        filter => $filter x 5,
        outputformat => "GML3",
    };

    my $features = FixMyStreet::Cobrand::UKCouncils->new->_fetch_features($cfg, $x, $y, 'xml');
    # Want the feature in the 'highest' category
    my @sort;
    foreach (@$features) {
        my $type = (keys %$_)[0];
        $type =~ s/ms://;
        push @sort, [ $cat_idx{$type}, $type ];
    }
    @sort = sort { $b->[0] <=> $a->[0] } @sort;
    return $sort[0][1];
}

sub munge_thamesmead_body {
    my ($self, $bodies) = @_;

    if ( my $category = $self->area_type_for_point ) {
        $self->{c}->stash->{'thamesmead_category'} = $category;
        %$bodies = map { $_->id => $_ } grep { $_->name eq 'Thamesmead' } values %$bodies;
    } else {
        $self->{c}->stash->{'thamesmead_category'} = '';
        %$bodies = map { $_->id => $_ } grep { $_->name ne 'Thamesmead' } values %$bodies;
    }
}

sub munge_categories {
    my ($self, $categories) = @_;

    if ($self->{c}->stash->{'thamesmead_category'}) {
        $self->{c}->stash->{'preselected_categories'} = { 'category' => $category_titles{ $self->{c}->stash->{'thamesmead_category'} }, 'subcategory' => '' };
    }
}

1;
