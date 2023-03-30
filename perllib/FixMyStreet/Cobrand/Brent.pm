package FixMyStreet::Cobrand::Brent;
use parent 'FixMyStreet::Cobrand::UKCouncils';

use strict;
use warnings;
use Moo;
use DateTime;
use FixMyStreet::App::Form::Waste::Request::Brent;
with 'FixMyStreet::Roles::Open311Multi';
with 'FixMyStreet::Roles::CobrandOpenUSRN';
with 'FixMyStreet::Roles::CobrandEcho';
with 'FixMyStreet::Roles::SCP';

sub council_area_id { return 2488; }
sub council_area { return 'Brent'; }
sub council_name { return 'Brent Council'; }
sub council_url { return 'brent'; }

sub path_to_pin_icons {
    return '/cobrands/brent/images/';
}

sub admin_user_domain { 'brent.gov.uk' }

sub allow_anonymous_reports { 'button' }

sub default_map_zoom { 6 }

sub privacy_policy_url {
    'https://www.brent.gov.uk/the-council-and-democracy/access-to-information/data-protection-and-privacy/brent-privacy-policy'
}

sub get_geocoder { 'OSM' }

sub reopening_disallowed { 1 }

sub enter_postcode_text {
    my ($self) = @_;
    return 'Enter a ' . $self->council_area . ' postcode, or street name';
}

sub disambiguate_location { {
    centre => '51.5585509362304,-0.26781886445231',
    span   => '0.0727325098393763,0.144085171830317',
    bounds => [ 51.52763684136, -0.335577710963202, 51.6003693511994, -0.191492539132886 ],
    town => 'Brent',
} }

sub geocoder_munge_results {
    my ($self, $result) = @_;

    $result->{display_name} =~ s/, London Borough of Brent, London, Greater London, England//;
}

sub categories_restriction {
    my ($self, $rs) = @_;

    # Brent don't want TfL's River Piers category to appear on their cobrand.
    return $rs->search( { 'me.category' => { '-not_like' => 'River Piers%' } } );
}

sub social_auth_enabled {
    my $self = shift;

    return $self->feature('oidc_login') ? 1 : 0;
}

sub user_from_oidc {
    my ($self, $payload) = @_;

    my $name = join(" ", $payload->{givenName}, $payload->{surname});
    my $email = $payload->{email};

    return ($name, $email);
}

sub open311_config {
    my ($self, $row, $h, $params) = @_;
    $params->{multi_photos} = 1;
}

sub open311_munge_update_params {
    my ($self, $params, $comment, $body) = @_;
    $params->{service_request_id_ext} = $comment->problem->id;
}

sub open311_extra_data_include {
    my ($self, $row, $h, $contact) = @_;

    my $open311_only;
    if ($contact->email =~ /^Symology/) {
        # Reports made via the app probably won't have a NSGRef because we don't
        # display the road layer. Instead we'll look up the closest asset from the
        # WFS service at the point we're sending the report over Open311.
        if (!$row->get_extra_field_value('NSGRef')) {
            if (my $ref = $self->lookup_site_code($row, 'usrn')) {
                $row->update_extra_field({ name => 'NSGRef', description => 'NSG Ref', value => $ref });
            }
        }

        if ($contact->groups->[0] eq 'Drains and gullies') {
            if (my $id = $row->get_extra_field_value('UnitID')) {
                $self->{brent_original_detail} = $row->detail;
                my $detail = $row->detail . "\n\nukey: $id";
                $row->detail($detail);
            }
        }
    } elsif ($contact->email =~ /^Echo/) {
        my $type = $contact->get_extra_metadata('type') || '';
        # Same as above, but different attribute name
        if ($type ne 'waste' && !$row->get_extra_field_value('usrn')) {
            if (my $ref = $self->lookup_site_code($row, 'usrn')) {
                $row->update_extra_field({ name => 'usrn', description => 'USRN', value => $ref });
            }
        }
    }

    push @$open311_only, { name => 'title', value => $row->title };
    push @$open311_only, { name => 'description', value => $row->detail };

    return $open311_only;
}

sub open311_extra_data_exclude {
    my ($self, $row, $h, $contact) = @_;

    return ['UnitID'] if $contact->groups->[0] eq 'Drains and gullies';
    return [];
}

sub open311_post_send {
    my ($self, $row) = @_;
    $row->detail($self->{brent_original_detail}) if $self->{brent_original_detail};
}

sub prevent_questionnaire_updating_status { 1 };

sub admin_templates_external_status_code_hook {
    my ($self) = @_;
    my $c = $self->{c};

    my $res_code = $c->get_param('resolution_code') || '';
    my $task_type = $c->get_param('task_type') || '';
    my $task_state = $c->get_param('task_state') || '';

    my $code = "$res_code,$task_type,$task_state";
    $code = '' if $code eq ',,';
    $code =~ s/,,$// if $code;

    return $code;
}

sub waste_check_staff_payment_permissions {
    my $self = shift;
    my $c = $self->{c};

    return unless $c->stash->{is_staff};

    $c->stash->{staff_payments_allowed} = 'paye';
}

sub waste_event_state_map {
    return {
        New => { New => 'confirmed' },
        Pending => {
            Unallocated => 'action scheduled',
            Accepted => 'action scheduled',
            'Allocated to Crew' => 'in progress',
            'Allocated to EM' => 'investigating',
            'Replacement Bin Required' => 'action scheduled',
        },
        Closed => {
            Closed => 'fixed - council',
            Completed => 'fixed - council',
            'Not Completed' => 'unable to fix',
            'Partially Completed' => 'closed',
            'No Repair Required' => 'unable to fix',
        },
        Cancelled => {
            Rejected => 'closed',
        },
    };
}

sub waste_on_the_day_criteria {
    my ($self, $completed, $state, $now, $row) = @_;

    return unless $now->hour < 22;
    if ($state eq 'Outstanding') {
        $row->{next} = $row->{last};
        $row->{next}{state} = 'In progress';
        delete $row->{last};
    }
    if (!$completed) {
        $row->{report_allowed} = 0;
    }
}

sub bin_services_for_address {
    my $self = shift;
    my $property = shift;

    $self->{c}->stash->{containers} = {
        1 => 'Blue rubbish sack',
        16 => 'General rubbish bin (grey bin)',
        8 => 'Clear recycling sack',
        6 => 'Recycling bin (blue bin)',
        11 => 'Food waste caddy',
        13 => 'Garden waste (green bin)',
    };

    $self->{c}->stash->{container_actions} = $self->waste_container_actions;

    my %service_to_containers = (
        262 => [ 16 ],
        265 => [ 6 ],
        269 => [ 8 ],
        316 => [ 11 ],
        317 => [ 13 ],
    );
    my %request_allowed = map { $_ => 1 } keys %service_to_containers;
    my %quantity_max = (
        262 => 1,
        265 => 1,
        269 => 1,
        316 => 1,
        317 => 5,
    );

    $self->{c}->stash->{quantity_max} = \%quantity_max;

    $self->{c}->stash->{garden_subs} = $self->waste_subscription_types;

    my $result = $self->{api_serviceunits};
    return [] unless @$result;

    my $events = $self->_parse_events($self->{api_events});
    $self->{c}->stash->{open_service_requests} = $events->{enquiry};

    # If there is an open Garden subscription (1159) event, assume
    # that means a bin is being delivered and so a pending subscription
    if ($events->{enquiry}{1159}) {
        $self->{c}->stash->{pending_subscription} = { title => 'Garden Subscription - New' };
        $self->{c}->stash->{open_garden_event} = 1;
    }

    my @to_fetch;
    my %schedules;
    my @task_refs;
    my %expired;
    foreach (@$result) {
        my $servicetask = $self->_get_current_service_task($_) or next;
        my $schedules = _parse_schedules($servicetask);
        $expired{$_->{Id}} = $schedules if $self->waste_sub_overdue( $schedules->{end_date}, weeks => 4 );

        next unless $schedules->{next} or $schedules->{last};
        $schedules{$_->{Id}} = $schedules;
        push @to_fetch, GetEventsForObject => [ ServiceUnit => $_->{Id} ];
        push @task_refs, $schedules->{last}{ref} if $schedules->{last};
    }
    push @to_fetch, GetTasks => \@task_refs if @task_refs;

    my $cfg = $self->feature('echo');
    my $echo = Integrations::Echo->new(%$cfg);
    my $calls = $echo->call_api($self->{c}, 'brent', 'bin_services_for_address:' . $property->{id}, 0, @to_fetch);

    my @out;
    my %task_ref_to_row;
    foreach (@$result) {
        my $service_id = $_->{ServiceId};
        my $service_name = $self->service_name_override($_);
        next unless $schedules{$_->{Id}} || ( $service_name eq 'Garden waste' && $expired{$_->{Id}} );

        my $schedules = $schedules{$_->{Id}} || $expired{$_->{Id}};
        my $servicetask = $self->_get_current_service_task($_);

        my $containers = $service_to_containers{$service_id};
        my $open_requests = { map { $_ => $events->{request}->{$_} } grep { $events->{request}->{$_} } @$containers };

        my $request_max = $quantity_max{$service_id};

        my $garden = 0;
        my $garden_bins;
        my $garden_cost = 0;
        my $garden_due = $self->waste_sub_due($schedules->{end_date});
        my $garden_overdue = $expired{$_->{Id}};
        if ($service_name eq 'Garden waste') {
            $garden = 1;
            my $data = Integrations::Echo::force_arrayref($servicetask->{Data}, 'ExtensibleDatum');
            foreach (@$data) {
                if ( $_->{DatatypeName} eq 'BRT - Paid Collection Container Quantity' ) {
                    $garden_bins = $_->{Value};
                    $garden_cost = $self->garden_waste_cost_pa($garden_bins) / 100;
                }
            }
            $request_max = $garden_bins;

            if ($self->{c}->stash->{waste_features}->{garden_disabled}) {
                $garden = 0;
            }
        }

        my $row = {
            id => $_->{Id},
            service_id => $service_id,
            service_name => $service_name,
            garden_waste => $garden,
            garden_bins => $garden_bins,
            garden_cost => $garden_cost,
            garden_due => $garden_due,
            garden_overdue => $garden_overdue,
            request_allowed => $request_allowed{$service_id} && $request_max && $schedules->{next},
            requests_open => $open_requests,
            request_containers => $containers,
            request_max => $request_max,
            service_task_id => $servicetask->{Id},
            service_task_name => $servicetask->{TaskTypeName},
            service_task_type_id => $servicetask->{TaskTypeId},
            schedule => $schedules->{description},
            last => $schedules->{last},
            next => $schedules->{next},
            end_date => $schedules->{end_date},
        };
        if ($row->{last}) {
            my $ref = join(',', @{$row->{last}{ref}});
            $task_ref_to_row{$ref} = $row;

            $row->{report_allowed} = $self->within_working_days($row->{last}{date}, 2);

            my $events_unit = $self->_parse_events($calls->{"GetEventsForObject ServiceUnit $_->{Id}"});
            my $missed_events = [
                @{$events->{missed}->{$service_id} || []},
                @{$events_unit->{missed}->{$service_id} || []},
            ];
            my $recent_events = $self->_events_since_date($row->{last}{date}, $missed_events);
            $row->{report_open} = $recent_events->{open} || $recent_events->{closed};
        }
        push @out, $row;
    }

    $self->waste_task_resolutions($calls->{GetTasks}, \%task_ref_to_row);

    return \@out;
}

sub waste_container_actions {
    return {
        deliver => 1,
        remove => 2
    };
}

sub waste_subscription_types {
    return {
        New => 1,
        Renew => 2,
        Amend => 3,
    };
}

sub _closed_event {
    my $event = shift;
    return 1 if $event->{ResolvedDate};
    return 0;
}

sub _parse_events {
    my $self = shift;
    my $events_data = shift;
    my $events;
    foreach (@$events_data) {
        my $event_type = $_->{EventTypeId};
        my $type = 'enquiry';
        $type = 'request' if $event_type == 1062;
        $type = 'missed' if $event_type == 918;

        # Only care about open requests/enquiries
        my $closed = _closed_event($_);
        next if $type ne 'missed' && $closed;

        if ($type eq 'request') {
            my $data = Integrations::Echo::force_arrayref($_->{Data}, 'ExtensibleDatum');
            my $container;
            DATA: foreach (@$data) {
                my $moredata = Integrations::Echo::force_arrayref($_->{ChildData}, 'ExtensibleDatum');
                foreach (@$moredata) {
                    if ($_->{DatatypeName} eq 'Container Type') {
                        $container = $_->{Value};
                        last DATA;
                    }
                }
            }
            my $report = $self->problems->search({ external_id => $_->{Guid} })->first;
            $events->{request}->{$container} = $report ? { report => $report } : 1;
        } elsif ($type eq 'missed') {
            my $report = $self->problems->search({ external_id => $_->{Guid} })->first;
            my $service_id = $_->{ServiceId};
            my $data = {
                closed => $closed,
                date => construct_bin_date($_->{EventDate}),
            };
            $data->{report} = $report if $report;
            push @{$events->{missed}->{$service_id}}, $data;
        } else { # General enquiry of some sort
            $events->{enquiry}->{$event_type} = 1;
        }
    }
    return $events;
}

sub image_for_unit {
    my ($self, $unit) = @_;
    my $service_id = $unit->{service_id};

    my $base = '/i/waste-containers';
    my $images = {
        262 => "$base/bin-grey",
        265 => "$base/bin-grey-blue-lid-recycling",
        316 => "$base/caddy-green-recycling",
        317 => "$base/bin-green",
        263 => "$base/large-communal-black",
        266 => "$base/large-communal-blue-recycling",
        271 => "$base/bin-brown",
        267 => "$base/sack-black",
        269 => "$base/sack-clear",
    };
    return $images->{$service_id};
}

sub bin_day_format { '%A, %-d~~~ %B' }

sub service_name_override {
    my ($self, $service) = @_;

    my %service_name_override = (
        262 => 'Rubbish',
        265 => 'Recycling',
        316 => 'Food waste',
        317 => 'Garden waste',
        263 => 'Communal rubbish',
        266 => 'Communal recycling',
        271 => 'Communal food waste',
        267 => 'Rubbish (black sacks)',
        269 => 'Recycling (clear sacks)',
    );

    return $service_name_override{$service->{ServiceId}} || $service->{ServiceName};
}

sub clear_cached_lookups_property {
    my ($self, $id) = @_;

    my $key = "brent:echo:look_up_property:$id";
    delete $self->{c}->session->{$key};
    $key = "brent:echo:bin_services_for_address:$id";
    delete $self->{c}->session->{$key};
}

sub within_working_days {
    my ($self, $dt, $days, $future) = @_;
    my $wd = FixMyStreet::WorkingDays->new(public_holidays => FixMyStreet::Cobrand::UK::public_holidays());
    $dt = $wd->add_days($dt, $days)->ymd;
    my $today = DateTime->now->set_time_zone(FixMyStreet->local_time_zone)->ymd;
    if ( $future ) {
        return $today ge $dt;
    } else {
        return $today le $dt;
    }
}

sub waste_munge_report_data {
    my ($self, $id, $data) = @_;

    my $c = $self->{c};

    my $address = $c->stash->{property}->{address};
    my $service = $c->stash->{services}{$id}{service_name};
    $data->{title} = "Report missed $service";
    $data->{detail} = "$data->{title}\n\n$address";
    $c->set_param('service_id', $id);
}

# Replace the usual checkboxes grouped by service with one radio list
sub waste_munge_request_form_fields {
    my ($self, $field_list) = @_;

    my @radio_options;
    my %seen;
    for (my $i=0; $i<@$field_list; $i+=2) {
        my ($key, $value) = ($field_list->[$i], $field_list->[$i+1]);
        next unless $key =~ /^container-(\d+)/;
        my $id = $1;
        push @radio_options, {
            value => $id,
            label => $self->{c}->stash->{containers}->{$id},
            disabled => $value->{disabled},
        };
        $seen{$id} = 1;
    }

    @$field_list = (
        "container-choice" => {
            type => 'Select',
            widget => 'RadioGroup',
            label => 'Which container do you need?',
            options => \@radio_options,
            required => 1,
        }
    );
}

sub waste_munge_request_data {
    my ($self, $id, $data, $form) = @_;

    my $c = $self->{c};

    my $address = $c->stash->{property}->{address};
    my $container = $c->stash->{containers}{$id};
    my $reason = $data->{request_reason} || '';
    my $nice_reason = $c->stash->{label_for_field}->($form, 'request_reason', $reason);

    my ($action_id, $reason_id);
    my $type = $id;
    my $quantity = 1;
    if ($reason eq 'damaged') {
        $action_id = '2::1'; # Collect/Deliver
        $reason_id = '4::4'; # Damaged
        $type = $id . '::' . $id;
        $quantity = '1::1';
    } elsif ($reason eq 'missing') {
        $action_id = 1; # Deliver
        $reason_id = 1; # Missing
    } elsif ($reason eq 'new_build') {
        $action_id = 1; # Deliver
        $reason_id = 6; # New Property
    } elsif ($reason eq 'extra') {
        $action_id = 1; # Deliver
        $reason_id = 9; # Increase capacity
    }

    $c->set_param('Container_Request_Action', $action_id);
    $c->set_param('Container_Request_Reason', $reason_id);
    $c->set_param('Container_Request_Container_Type', $type);
    $c->set_param('Container_Request_Quantity', $quantity);

    $data->{title} = "Request new $container";
    $data->{detail} = "Quantity: 1\n\n$address";
    $data->{detail} .= "\n\nReason: $nice_reason" if $nice_reason;

    my $notes;
    if ($data->{notes_damaged}) {
        $notes = $c->stash->{label_for_field}->($form, 'notes_damaged', $data->{notes_damaged});
        $data->{detail} .= " - $notes";
    }
    if ($data->{details_damaged}) {
        $data->{detail} .= "\n\nDamage reported during collection: " . $data->{details_damaged};
        $notes .= " - " . $data->{details_damaged};
    }
    $c->set_param('Container_Request_Notes', $notes) if $notes;

    # XXX Share somewhere with reverse?
    my %service_id = (
        16 => 262,
        6 => 265,
        8 => 269,
        11 => 316,
        13 => 317,
    );
    $c->set_param('service_id', $service_id{$id});
}

sub waste_request_form_first_next {
    my $self = shift;

    $self->{c}->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Request::Brent';
    $self->{c}->stash->{form_title} = 'Which container do you need?';

    return sub {
        my $data = shift;
        my $choice = $data->{"container-choice"};
        return 'request_refuse_call_us' if $choice == 16;
        return 'replacement';
    };
}

# Take the chosen container and munge it into the normal data format
sub waste_munge_request_form_data {
    my ($self, $data) = @_;
    my $container_id = delete $data->{'container-choice'};
    $data->{"container-$container_id"} = 1;
}

sub waste_staff_choose_payment_method { 0 }
sub waste_cheque_payments { 0 }

use constant GARDEN_WASTE_SERVICE_ID => 317;
use constant GARDEN_WASTE_PAID_COLLECTION_CONTAINER_TYPE => 1;
sub garden_service_name { 'Garden waste collection service' }
sub garden_service_id { GARDEN_WASTE_SERVICE_ID }
sub garden_current_subscription { shift->{c}->stash->{services}{+GARDEN_WASTE_SERVICE_ID} }
sub get_current_garden_bins { shift->garden_current_subscription->{garden_bins} }
sub garden_due_days { 28 }

sub garden_current_service_from_service_units {
    my ($self, $services) = @_;

    my $garden;
    for my $service ( @$services ) {
        if ( $service->{ServiceId} == GARDEN_WASTE_SERVICE_ID ) {
            $garden = $self->_get_current_service_task($service);
            last;
        }
    }

    return $garden;
}

sub bin_payment_types {
    return {
        'csc' => 1,
        'credit_card' => 2,
        'direct_debit' => 3,
        'cheque' => 4,
    };
}

sub waste_cc_payment_line_item_ref {
    my ($self, $p) = @_;
    return "Brent-" . $p->id;
}

sub waste_cc_payment_sale_ref {
    my ($self, $p) = @_;
    return "Brent-" . $p->id;
}

sub waste_munge_enquiry_data {
    my ($self, $data) = @_;

    my $address = $self->{c}->stash->{property}->{address};
    $data->{title} = $data->{category};

    my $detail;
    foreach (sort grep { /^extra_/ } keys %$data) {
        $detail .= "$data->{$_}\n\n";
    }
    $detail .= $address;
    $data->{detail} = $detail;
}

sub waste_cc_payment_admin_fee_line_item_ref {
    my ($self, $p) = @_;
    return "Brent-" . $p->id;
}


sub waste_garden_sub_params {
    my ($self, $data, $type) = @_;
    my $c = $self->{c};

    my %container_types = map { $c->{stash}->{containers}->{$_} => $_ } keys %{ $c->stash->{containers} };
    $c->set_param('Paid_Collection_Container_Type', GARDEN_WASTE_PAID_COLLECTION_CONTAINER_TYPE);
    $c->set_param('Paid_Collection_Container_Quantity', $data->{bins_wanted});
    $c->set_param('Payment_Value', $data->{cost_pa});
    # $c->set_param('Payment Authorisation Code') is possibly set as payment_reference
    if ( $data->{new_bins} > 0 ) {
        $c->set_param('Container_Type', GARDEN_WASTE_PAID_COLLECTION_CONTAINER_TYPE);
        $c->set_param('Container_Quantity', $data->{new_bins});
    }
}

sub garden_waste_cost_pa {
    my ($self, $bin_count) = @_;

    $bin_count ||= 1;

    my $cost = $self->feature('payment_gateway')->{ggw_cost} * $bin_count;
    my $now = DateTime->now( time_zone => FixMyStreet->local_time_zone );

    if ($now->month =~ /^(10|11|12)$/ ) {
        $cost = $cost/2;
    }

    return $cost;
}

sub garden_waste_new_bin_admin_fee { 0 }

1;
