=head1 NAME

FixMyStreet::Cobrand::WestNorthants - code specific to the West Northamptonshire cobrand.

=head1 SYNOPSIS

=head1 DESCRIPTION

=cut

package FixMyStreet::Cobrand::WestNorthants;
use base 'FixMyStreet::Cobrand::UKCouncils';

use strict;
use warnings;

use Moo;

# This cobrand is integrated with Kier's works manager but
# makes use of the same attributes as Alloy and validation
# checks for Confirm.
with 'FixMyStreet::Roles::ConfirmValidation';
with 'FixMyStreet::Roles::Open311Alloy';
with 'FixMyStreet::Roles::CobrandNorthants';

=head2 Defaults

=over 4

=cut

sub council_area_id { return 164186; }
sub council_area { return 'West Northamptonshire'; }
sub council_name { return 'West Northamptonshire Council'; }
sub council_url { return 'westnorthants'; }

sub privacy_policy_url {
    'https://www.westnorthants.gov.uk/service-privacy-notices/street-doctor-privacy-policy'
}

sub enter_postcode_text { 'Enter a West Northamptonshire postcode, street name and area, or check an existing report number' }

sub disambiguate_location {
    my $self    = shift;
    my $string  = shift;

    return {
        %{ $self->SUPER::disambiguate_location() },
        centre => '52.2230321460526,-1.03613790739017',
        span   => '0.500177808954568,0.627284685758849',
        bounds => [ 51.9772677832173, -1.33234611641128, 52.4774455921719, -0.705061430652433 ],
    };
}

=item * Users with a westnorthants.gov.uk email can always be found in the admin.

=cut

sub admin_user_domain { 'westnorthants.gov.uk' }

sub _problems_restriction_areas { [
    '%,2392,%', # South Northamptonshire.
    '%,2394,%', # Daventry.
    '%,2397,%', # Northampton.
    '%,164186,%', # West Northamptonshire.
] }

=item * Defects are coloured blue.

Ideally this would be in Roles::CobrandNorthants, but that can't call $self->SUPER.

=cut

sub pin_colour {
    my ($self, $p, $context) = @_;
    return 'blue' if $self->is_defect($p);
    return $self->SUPER::pin_colour($p, $context);
}

1;
