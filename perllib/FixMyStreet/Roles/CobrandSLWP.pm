=head1 NAME

FixMyStreet::Roles::CobrandSLWP - shared code for Kingston and Sutton WasteWorks

=head1 DESCRIPTION

=cut

package FixMyStreet::Roles::CobrandSLWP;

use Moo::Role;
with 'FixMyStreet::Roles::CobrandEcho';
with 'FixMyStreet::Roles::CobrandBulkyWaste';

use Integrations::Echo;
use JSON::MaybeXS;
use LWP::Simple;
use MIME::Base64;
use FixMyStreet::WorkingDays;
use FixMyStreet::App::Form::Waste::Garden::Sacks;
use FixMyStreet::App::Form::Waste::Garden::Sacks::Renew;
use FixMyStreet::App::Form::Waste::Report::SLWP;
use FixMyStreet::App::Form::Waste::Request::Kingston;
use FixMyStreet::App::Form::Waste::Request::Sutton;

=head2 Defaults

=over 4

=item * We do not send questionnaires.

=cut

sub send_questionnaires { 0 }

=item * The contact form is for abuse reports only

=cut

sub abuse_reports_only { 1 }

=item * Only waste reports are shown on the cobrand

=cut

around problems_restriction => sub {
    my ($orig, $self, $rs) = @_;
    return $rs if FixMyStreet->staging_flag('skip_checks');
    $rs = $orig->($self, $rs);
    my $table = ref $rs eq 'FixMyStreet::DB::ResultSet::Nearby' ? 'problem' : 'me';
    $rs = $rs->search({
        "$table.cobrand_data" => 'waste',
    });
    return $rs;
};

=item * We can send multiple photos through to Echo, directly

=cut

sub open311_config {
    my ($self, $row, $h, $params, $contact) = @_;
    $params->{multi_photos} = 1;
    $params->{upload_files} = 1;
}

=item * When a garden subscription is sent to Echo, we include payment details

=cut

sub open311_extra_data_include {
    my ($self, $row, $h) = @_;

    my $open311_only = [
        #{ name => 'email', value => $row->user->email }
    ];

    if ( $row->category eq 'Garden Subscription' ) {
        if ( $row->get_extra_metadata('contributed_as') && $row->get_extra_metadata('contributed_as') eq 'anonymous_user' ) {
            push @$open311_only, { name => 'contributed_as', value => 'anonymous_user' };
        }

        my $ref = $row->get_extra_field_value('PaymentCode') || $row->get_extra_metadata('chequeReference');
        push @$open311_only, { name => 'Transaction_Number', value => $ref } if $ref;

        my $payment = $row->get_extra_field_value('pro_rata') || $row->get_extra_field_value('payment');
        my $admin_fee = $row->get_extra_field_value('admin_fee');
        $payment += $admin_fee if $admin_fee;
        if ($payment) {
            my $amount = sprintf( '%.2f', $payment / 100 );
            push @$open311_only, { name => 'Payment_Amount', value => $amount };
        }
    }

    return $open311_only;
}

=item * If Echo errors, we try and deal with standard issues - a renewal on an expired subscription, or a duplicate event

=cut

sub open311_post_send {
    my ($self, $row, $h, $sender) = @_;
    my $error = $sender->error;
    my $db = FixMyStreet::DB->schema->storage;
    $db->txn_do(sub {
        my $row2 = FixMyStreet::DB->resultset('Problem')->search({ id => $row->id }, { for => \'UPDATE' })->single;
        if ($error =~ /Cannot renew this property, a new request is required/ && $row2->title eq "Garden Subscription - Renew") {
            # Was created as a renewal, but due to DD delay has now expired. Switch to new subscription
            $row2->title("Garden Subscription - New");
            $row2->update_extra_field({ name => "Request_Type", value => $self->waste_subscription_types->{New} });
            $row2->update;
            $row->discard_changes;
        } elsif ($error =~ /Missed Collection event already open for the property/) {
            $row2->state('duplicate');
            $row2->update;
            $row->discard_changes;
        } elsif ($error =~ /Selected reservations expired|Invalid reservation reference/) {
            $self->bulky_refetch_slots($row2);
            $row->discard_changes;
        } elsif ($error =~ /Duplicate Event! Original eventID: (\d+)/) {
            my $id = $1;
            my $cfg = $self->feature('echo');
            my $echo = Integrations::Echo->new(%$cfg);
            my $event = $echo->GetEvent($id, 'Id');
            $row2->external_id($event->{Guid});
            $sender->success(1);
            $row2->update;
            $row->discard_changes;
        }
    });
}

=item * Look for completion photos on updates

=cut

sub open311_waste_update_extra {
    my ($self, $cfg, $event) = @_;

    # Could have got here with a full event (pull) or subset (push)
    if (!$event->{Data}) {
        $event = $cfg->{echo}->GetEvent($event->{Guid});
    }
    my $data = Integrations::Echo::force_arrayref($event->{Data}, 'ExtensibleDatum');
    my @media;
    foreach (@$data) {
        if ($_->{DatatypeName} eq 'Post Collection Photo' || $_->{DatatypeName} eq 'Pre Collection Photo') {
            my $value = decode_base64($_->{Value});
            my $type = FixMyStreet::PhotoStorage->detect_type($value);
            push @media, "data:image/$type,$value";
        }
    }
    return @media ? ( media_url => \@media ) : ();
}

=item * No updates on waste reports

=cut

around updates_disallowed => sub {
    my ($orig, $self, $problem) = @_;

    # No updates on waste reports
    return 'waste' if $problem->cobrand_data eq 'waste';

    return $orig->($self, $problem);
};

sub state_groups_admin {
    [
        [ New => [ 'confirmed' ] ],
        [ Pending => [ 'investigating', 'action scheduled' ] ],
        [ Closed => [ 'fixed - council', 'unable to fix', 'closed', 'duplicate', 'cancelled' ] ],
        [ Hidden => [ 'unconfirmed', 'hidden', 'partial' ] ],
    ]
}

# Cut down list as only Waste
sub available_permissions {
    my $self = shift;

    return {
        _("Problems") => {
            report_edit => _("Edit reports"),
            report_mark_private => _("View/Mark private reports"),
            contribute_as_another_user => _("Create reports/updates on a user's behalf"),
            contribute_as_anonymous_user => _("Create reports/updates as anonymous user"),
            contribute_as_body => _("Create reports/updates as the council"),
        },
        _("Users") => {
            user_edit => _("Edit users' details/search for their reports"),
            user_manage_permissions => _("Edit other users' permissions"),
            user_assign_body => _("Grant access to the admin"),
        },
        _("Bodies") => {
            template_edit => _("Add/edit response templates"),
            emergency_message_edit => _("Add/edit site message"),
        },
        Waste => {
            wasteworks_config => "Can edit WasteWorks configuration",
        },
    };
}

around look_up_property => sub {
    my ($orig, $self, $id) = @_;
    my $data = $orig->($self, $id);

    my $cfg = $self->feature('echo');
    if ($cfg->{nlpg} && $data->{uprn} && !$self->{c}->stash->{partial_loading}) {
        my $uprn_data = get(sprintf($cfg->{nlpg}, $data->{uprn}));
        $uprn_data = JSON::MaybeXS->new->decode($uprn_data) if $uprn_data;
        if (!$uprn_data || $uprn_data->{results}[0]{LPI}{LOCAL_CUSTODIAN_CODE_DESCRIPTION} ne $self->lpi_value) {
            $self->{c}->stash->{template} = 'waste/missing.html';
            $self->{c}->detach;
        }
    }
    return $data;
};

sub waste_auto_confirm_report { 1 }

sub waste_staff_choose_payment_method { 1 }
sub waste_cheque_payments { shift->{c}->stash->{staff_payments_allowed} }

sub waste_event_state_map {
    return {
        New => { New => 'confirmed' },
        Pending => {
            Unallocated => 'investigating',
            #'Allocated to Crew' => 'action scheduled',
            #Accepted => 'action scheduled',
        },
        Closed => {
            Closed => 'fixed - council',
            Completed => 'fixed - council',
            'Not Completed' => 'unable to fix',
            'Partially Completed' => 'closed',
            Rejected => 'closed',
        },
        Cancelled => {
            Cancelled => 'cancelled',
        },
    };
}

use constant CONTAINER_REFUSE_140 => 1;
use constant CONTAINER_REFUSE_240 => 2;
use constant CONTAINER_REFUSE_360 => 3;
use constant CONTAINER_RECYCLING_BIN => 12;
use constant CONTAINER_RECYCLING_BOX => 16;
use constant CONTAINER_PAPER_BIN => 19;
use constant CONTAINER_PAPER_BIN_140 => 36;

sub garden_service_name { 'garden waste collection service' }
sub garden_service_id { 2247 }

sub garden_echo_container_name { 'SLWP - Containers' }
sub garden_due_days { 30 }

sub garden_subscription_email_renew_reminder_opt_in { 0 }

sub garden_current_service_from_service_units {
    my ($self, $services) = @_;

    my $garden;
    for my $service ( @$services ) {
        my $servicetasks = $self->_get_service_tasks($service);
        foreach my $task (@$servicetasks) {
            if ( $task->{TaskTypeId} == $self->garden_service_id ) {
                $garden = $self->_get_current_service_task($service);
                last;
            }
        }
    }
    return $garden;
}

sub service_name_override {
    my ($self, $service) = @_;

    my %service_name_override = (
        2238 => 'Non-recyclable Refuse',
        2239 => 'Food waste',
        2240 => 'Paper and card',
        2241 => 'Mixed recycling',
        2242 => 'Non-recyclable Refuse',
        2243 => 'Non-recyclable Refuse',
        2246 => 'Mixed recycling',
        2247 => 'Garden Waste',
        2248 => "Food waste",
        2249 => "Paper and card",
        2250 => "Mixed recycling",
        2632 => 'Paper and card',
        3571 => 'Mixed recycling',
        3576 => 'Non-recyclable Refuse',
        2256 => '', # Deliver refuse bags
        2257 => '', # Deliver recycling bags
    );

    return $service_name_override{$service->{ServiceId}} // '';
}

sub waste_password_hidden { 1 }

# For renewal/modify
sub waste_allow_current_bins_edit { 1 }

sub waste_containers {
    my $self = shift;
    my %shared = (
            4 => 'Refuse Blue Sack',
            5 => 'Refuse Black Sack',
            6 => 'Refuse Red Stripe Bag',
            18 => 'Mixed Recycling Blue Striped Bag',
            29 => 'Recycling Single Use Bag',
            21 => 'Paper & Card Reusable Bag',
            22 => 'Paper Sacks',
            30 => 'Paper & Card Recycling Clear Bag',
            7 => 'Communal Refuse bin (240L)',
            8 => 'Communal Refuse bin (360L)',
            9 => 'Communal Refuse bin (660L)',
            10 => 'Communal Refuse bin (1100L)',
            11 => 'Communal Refuse Chamberlain',
            33 => 'Communal Refuse bin (140L)',
            34 => 'Communal Refuse bin (1280L)',
            14 => 'Communal Recycling bin (660L)',
            15 => 'Communal Recycling bin (1100L)',
            25 => 'Communal Food bin (240L)',
            12 => 'Recycling bin (240L)',
            13 => 'Recycling bin (360L)',
            20 => 'Paper recycling bin (360L)',
            31 => 'Paper 55L Box',
    );
    if ($self->moniker eq 'sutton') {
        return {
            %shared,
            1 => 'Standard Brown General Waste Wheelie Bin (140L)',
            2 => 'Larger Brown General Waste Wheelie Bin (240L)',
            3 => 'Extra Large Brown General Waste Wheelie Bin (360L)',
            35 => 'Rubbish bin (180L)',
            16 => 'Mixed Recycling Green Box (55L)',
            19 => 'Paper and Cardboard Green Wheelie Bin (240L)',
            36 => 'Paper and Cardboard Green Wheelie Bin (140L)',
            23 => 'Small Kitchen Food Waste Caddy (7L)',
            24 => 'Large Outdoor Food Waste Caddy (23L)',
            26 => 'Garden Waste Wheelie Bin (240L)',
            27 => 'Garden Waste Wheelie Bin (140L)',
            28 => 'Garden waste sacks',
        };
    } elsif ($self->moniker eq 'kingston') {
        return {
            %shared,
            1 => 'Black rubbish bin (140L)',
            2 => 'Black rubbish bin (240L)',
            3 => 'Black rubbish bin (360L)',
            35 => 'Black rubbish bin (180L)',
            12 => 'Green recycling bin (240L)',
            13 => 'Green recycling bin (360L)',
            16 => 'Green recycling box (55L)',
            19 => 'Blue lid paper and cardboard bin (240L)',
            20 => 'Blue lid paper and cardboard bin (360L)',
            23 => 'Food waste bin (kitchen)',
            24 => 'Food waste bin (outdoor)',
            36 => 'Blue lid paper and cardboard bin (180L)',
            26 => 'Garden waste bin (240L)',
            27 => 'Garden waste bin (140L)',
            28 => 'Garden waste sacks',
        };
    }
}

sub waste_service_to_containers { () }

sub waste_quantity_max {
    return (
        2247 => 5, # Garden waste maximum
    );
}

sub garden_subscription_event_id { 1638 }

sub waste_bulky_missed_blocked_codes {
    return {
        # Partially completed
        12399 => {
            507 => 'Not all items presented',
            380 => 'Some items too heavy',
        },
        # Completed
        12400 => {
            606 => 'More items presented than booked',
        },
        # Not Completed
        12401 => {
            460 => 'Nothing out',
            379 => 'Item not as described',
            100 => 'No access',
            212 => 'Too heavy',
            473 => 'Damage on site',
            234 => 'Hazardous waste',
        },
    };
}

sub waste_relevant_serviceunits {
    my ($self, $result) = @_;
    my @rows;
    foreach (@$result) {
        my $servicetasks = $self->_get_service_tasks($_);
        foreach my $task (@$servicetasks) {
            my $service_id = $task->{TaskTypeId};
            my $service_name = $self->service_name_override({ ServiceId => $service_id });
            next unless $service_name;

            my $schedules = _parse_schedules($task, 'task');

            # Ignore retired diesel rounds
            next if $self->moniker eq 'kingston' && !$schedules->{next} && $service_id != $self->garden_service_id;

            push @rows, {
                Id => $task->{Id},
                ServiceId => $task->{TaskTypeId},
                ServiceTask => $task,
                Schedules => $schedules,
            };
        }
    }
    return @rows;
}

sub waste_extra_service_info_all_results {
    my ($self, $property, $result) = @_;

    if (!(@$result && grep { $_->{ServiceId} == 409 } @$result)) {
        # No garden collection possible
        $self->{c}->stash->{waste_features}->{garden_disabled} = 1;
    }

    $property->{has_no_services} = scalar @$result == 0;

    foreach (@$result) {
        my $data = Integrations::Echo::force_arrayref($_->{Data}, 'ExtensibleDatum');
        foreach (@$data) {
            $self->{c}->stash->{assisted_collection} = 1 if $_->{DatatypeName} eq "Assisted Collection" && $_->{Value};
        }
    }
}

sub waste_extra_service_info {
    my ($self, $property, @rows) = @_;

    foreach (@rows) {
        my $service_id = $_->{ServiceId};
        if ($service_id == 2242) { # Collect Domestic Refuse Bag
            $self->{c}->stash->{slwp_garden_sacks} = 1;
        } elsif ($service_id == 2238) { # Collect Domestic Refuse Bin
            $property->{domestic_refuse_bin} = 1;
        }
        $self->{c}->stash->{communal_property} = 1 if $service_id == 2243 || $service_id == 2248 || $service_id == 2249 || $service_id == 2250; # Communal
    }
}

my %waste_containers_no_request = (
    6 => 1, # Red stripe bag
    17 => 1, # Recycling purple sack
    29 => 1, # Recycling Single Use Bag
    21 => 1, # Paper & Card Reusable bag
);

sub waste_service_containers {
    my ($self, $service) = @_;

    my $task = $service->{ServiceTask};
    my $service_id = $service->{ServiceId};
    my $service_name = $self->service_name_override($service);
    my $schedules = $service->{Schedules};

    my $data = Integrations::Echo::force_arrayref($task->{Data}, 'ExtensibleDatum');
    my ($containers, $request_max);
    foreach (@$data) {
        next if $service_id == 2243 || $service_id == 2248 || $service_id == 2249 || $service_id == 2250; # Communal
        my $moredata = Integrations::Echo::force_arrayref($_->{ChildData}, 'ExtensibleDatum');
        my ($container, $quantity) = (0, 0);
        foreach (@$moredata) {
            $container = $_->{Value} if $_->{DatatypeName} eq 'Container Type' || $_->{DatatypeName} eq 'Container';
            $quantity = $_->{Value} if $_->{DatatypeName} eq 'Quantity';
        }
        next if $waste_containers_no_request{$container};
        next if $container == 18 && $schedules->{description} !~ /fortnight/; # Blue stripe bag on a weekly collection
        if ($container && $quantity) {
            # Store this fact here for use in new request flow
            $self->{c}->stash->{container_recycling_bin} = 1 if $container == CONTAINER_RECYCLING_BIN;
            push @$containers, $container;
            next if $container == 28; # Garden waste bag
            # The most you can request is one
            $request_max->{$container} = 1;
            $self->{c}->stash->{quantities}->{$container} = $quantity;

            if ($self->moniker eq 'sutton') {
                if ($container == CONTAINER_REFUSE_140 || $container == CONTAINER_REFUSE_360) {
                    push @$containers, CONTAINER_REFUSE_240;
                    $request_max->{+CONTAINER_REFUSE_240} = 1;
                } elsif ($container == CONTAINER_REFUSE_240) {
                    push @$containers, CONTAINER_REFUSE_140;
                    $request_max->{+CONTAINER_REFUSE_140} = 1;
                } elsif ($container == CONTAINER_PAPER_BIN_140) {
                    $request_max->{+CONTAINER_PAPER_BIN} = 1;
                    # Swap 140 for 240 in container list
                    @$containers = map { $_ == CONTAINER_PAPER_BIN_140 ? CONTAINER_PAPER_BIN : $_ } @$containers;
                }
            }
        }
    }

    if ($service_name =~ /Food/) {
        # Can always request a food caddy
        push @$containers, 23; # Food waste bin (kitchen)
        $request_max->{23} = 1;
    }
    if ($self->moniker eq 'kingston' && grep { $_ == CONTAINER_RECYCLING_BOX } @$containers) {
        # Can request a bin if you have a box
        push @$containers, CONTAINER_RECYCLING_BIN;
        $request_max->{+CONTAINER_RECYCLING_BIN} = 1;
    }

    return ($containers, $request_max);
}

sub waste_munge_bin_services_open_requests {
    my ($self, $open_requests) = @_;
    if ($self->moniker eq 'sutton') {
        if ($open_requests->{+CONTAINER_REFUSE_140}) {
            $open_requests->{+CONTAINER_REFUSE_240} = $open_requests->{+CONTAINER_REFUSE_140};
        } elsif ($open_requests->{+CONTAINER_REFUSE_240}) {
            $open_requests->{+CONTAINER_REFUSE_140} = $open_requests->{+CONTAINER_REFUSE_240};
            $open_requests->{+CONTAINER_REFUSE_360} = $open_requests->{+CONTAINER_REFUSE_240};
        }
        if ($open_requests->{+CONTAINER_PAPER_BIN_140}) {
            $open_requests->{+CONTAINER_PAPER_BIN} = $open_requests->{+CONTAINER_PAPER_BIN_140};
        }
    }
}

sub garden_container_data_extract {
    my ($self, $data, $containers, $quantities, $schedules) = @_;
    # Assume garden will only have one container data
    my $garden_container = $containers->[0];
    my $garden_bins = $quantities->{$containers->[0]};
    if ($garden_container == 28) {
        my $garden_cost = $self->garden_waste_renewal_sacks_cost_pa($schedules->{end_date}) / 100;
        return ($garden_bins, 1, $garden_cost, $garden_container);
    } else {
        my $garden_cost = $self->garden_waste_renewal_cost_pa($schedules->{end_date}, $garden_bins) / 100;
        return ($garden_bins, 0, $garden_cost, $garden_container);
    }
}

sub missed_event_types { {
    1635 => 'request',
    1566 => 'missed',
    1568 => 'missed',
    1571 => 'missed',
    1636 => 'bulky',
} }

sub parse_event_missed {
    my ($self, $echo_event, $closed, $events) = @_;
    my $report = $self->problems->search({ external_id => $echo_event->{Guid} })->first;
    my $event = {
        closed => $closed,
        date => construct_bin_date($echo_event->{EventDate}),
    };
    $event->{report} = $report if $report;

    my $service_id = $echo_event->{ServiceId};
    if ($service_id == 405) {
        push @{$events->{missed}->{2238}}, $event;
        push @{$events->{missed}->{2242}}, $event;
        push @{$events->{missed}->{3576}}, $event;
    } elsif ($service_id == 406) {
        push @{$events->{missed}->{2243}}, $event;
    } elsif ($service_id == 409) {
        push @{$events->{missed}->{2247}}, $event;
    } elsif ($service_id == 420) { # TODO Will food events come in as this?
        push @{$events->{missed}->{2239}}, $event;
        push @{$events->{missed}->{2248}}, $event;
    } elsif ($service_id == 413) {
        push @{$events->{missed}->{413}}, $event;
    } elsif ($service_id == 408 || $service_id == 410) {
        my $data = Integrations::Echo::force_arrayref($echo_event->{Data}, 'ExtensibleDatum');
        foreach (@$data) {
            if ($_->{DatatypeName} eq 'Paper' && $_->{Value} == 1) {
                push @{$events->{missed}->{2240}}, $event;
                push @{$events->{missed}->{2249}}, $event;
                push @{$events->{missed}->{2632}}, $event;
            } elsif ($_->{DatatypeName} eq 'Container Mix' && $_->{Value} == 1) {
                push @{$events->{missed}->{2241}}, $event;
                push @{$events->{missed}->{2246}}, $event;
                push @{$events->{missed}->{2250}}, $event;
                push @{$events->{missed}->{3571}}, $event;
            } elsif ($_->{DatatypeName} eq 'Food' && $_->{Value} == 1) {
                push @{$events->{missed}->{2239}}, $event;
                push @{$events->{missed}->{2248}}, $event;
            }
        }
    } else {
        push @{$events->{missed}->{$service_id}}, $event;
    }
}

# Not in the function below because it needs to set things needed before then
# (perhaps could be refactored better at some point). Used for new/renew
sub waste_garden_sub_payment_params {
    my ($self, $data) = @_;
    my $c = $self->{c};

    # Special sack form handling
    my $container = $data->{container_choice} || '';
    if ($container eq 'sack') {
        $data->{slwp_garden_sacks} = 1;
        $data->{bin_count} = 1;
        $data->{new_bins} = 1;
        my $cost_pa = $c->cobrand->garden_waste_sacks_cost_pa();
        ($cost_pa) = $c->cobrand->apply_garden_waste_discount($cost_pa) if $data->{apply_discount};
        $c->set_param('payment', $cost_pa);
    }
}

sub waste_garden_sub_params {
    my ($self, $data, $type) = @_;
    my $c = $self->{c};

    my $service = $self->garden_current_subscription;
    my $existing = $service ? $service->{garden_container} : undef;
    my $container = $data->{slwp_garden_sacks} ? 28 : $existing || 26;
    my $container_actions = {
        deliver => 1,
        remove => 2
    };

    $c->set_param('Request_Type', $type);
    $c->set_param('Subscription_Details_Containers', $container);
    $c->set_param('Subscription_Details_Quantity', $data->{bin_count});
    if ( $data->{new_bins} ) {
        my $action = ($data->{new_bins} > 0) ? 'deliver' : 'remove';
        $c->set_param('Bin_Delivery_Detail_Containers', $container_actions->{$action});
        $c->set_param('Bin_Delivery_Detail_Container', $container);
        $c->set_param('Bin_Delivery_Detail_Quantity', abs($data->{new_bins}));
    }
}

sub waste_garden_subscribe_form_setup {
    my ($self) = @_;
    my $c = $self->{c};
    if ($c->stash->{slwp_garden_sacks}) {
        $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Garden::Sacks';
    }
}

sub waste_garden_renew_form_setup {
    my ($self) = @_;
    my $c = $self->{c};
    if ($c->stash->{slwp_garden_sacks}) {
        $c->stash->{first_page} = 'sacks_choice';
        $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Garden::Sacks::Renew';
    }
}

=head2 waste_munge_report_form_fields

We use a custom report form to add some text to the "About you" page.

=cut

sub waste_munge_report_form_fields {
    my ($self, $field_list) = @_;
    $self->{c}->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Report::SLWP';
}

=head2 waste_munge_request_form_fields

Replace the usual checkboxes grouped by service with one radio list of
containers.

=cut

sub waste_request_single_radio_list { 1 }

sub waste_munge_request_form_fields {
    my ($self, $field_list) = @_;
    my $c = $self->{c};

    my @radio_options;
    my @replace_options;
    my %seen;
    for (my $i=0; $i<@$field_list; $i+=2) {
        my ($key, $value) = ($field_list->[$i], $field_list->[$i+1]);
        next unless $key =~ /^container-(\d+)/;
        my $id = $1;
        next if $self->moniker eq 'kingston' && $seen{$id};

        my ($cost, $hint);
        if ($self->moniker eq 'sutton') {
            ($cost, $hint) = $self->request_cost($id, $c->stash->{quantities});
        }

        my $data = {
            value => $id,
            label => $self->{c}->stash->{containers}->{$id},
            disabled => $value->{disabled},
            $hint ? (hint => $hint) : (),
        };
        my $change_cost = $self->_get_cost('request_change_cost');
        if ($cost && $change_cost && $cost == $change_cost) {
            push @replace_options, $data;
        } else {
            push @radio_options, $data;
        }
        $seen{$id} = 1;
    }

    if (@replace_options) {
        $radio_options[0]{tags}{divider_template} = "waste/request/intro_replace";
        $replace_options[0]{tags}{divider_template} = "waste/request/intro_change";
        push @radio_options, @replace_options;
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

=head2 waste_report_form_first_next

After picking a service, we jump straight to the about you page unless it's
bulky, where we ask for more information.

=cut

sub waste_report_form_first_next {
    my $self = shift;
    my $cfg = $self->feature('echo');
    my $bulky_service_id = $cfg->{bulky_service_id};
    return sub {
        my $data = shift;
        return 'notes' if $data->{"service-$bulky_service_id"};
        return 'about_you';
    };
}

=head2 waste_request_form_first_next

After picking a container, we jump straight to the about you page if they've
picked a bag or Sutton changing size, to the swap-for-a-bin page if they've
picked a bin, don't already have a bin and are on Kingston; otherwise we move
to asking for a reason.

=cut

sub waste_request_form_first_title { 'Which container do you need?' }
sub waste_request_form_first_next {
    my $self = shift;
    my $cls = ucfirst $self->council_url;
    my $containers = $self->{c}->stash->{quantities};
    return sub {
        my $data = shift;
        my $choice = $data->{"container-choice"};
        return 'about_you' if $choice == 18 || $choice == 30;
        if ($cls eq 'Kingston' && $choice == CONTAINER_RECYCLING_BIN && !$self->{c}->stash->{container_recycling_bin}) {
            $data->{request_reason} = 'more';
            return 'recycling_swap';
        }
        if ($cls eq 'Sutton') {
            foreach (CONTAINER_REFUSE_140, CONTAINER_REFUSE_240, CONTAINER_PAPER_BIN) {
                if ($choice == $_ && !$containers->{$_}) {
                    $data->{request_reason} = 'change_capacity';
                    return 'about_you';
                }
            }
        }
        return 'replacement';
    };
}

# Take the chosen container and munge it into the normal data format
sub waste_munge_request_form_data {
    my ($self, $data) = @_;
    my $container_id = delete $data->{'container-choice'};
    $data->{"container-$container_id"} = 1;
}

sub waste_munge_request_data {
    my ($self, $id, $data, $form) = @_;

    my $c = $self->{c};
    my $address = $c->stash->{property}->{address};
    my $container = $c->stash->{containers}{$id};
    my $quantity = $data->{recycling_quantity} || 1;
    my $reason = $data->{request_reason} || '';
    my $nice_reason = $c->stash->{label_for_field}->($form, 'request_reason', $reason);

    my ($action_id, $reason_id);
    if ($reason eq 'damaged') {
        $action_id = 3; # Replace
        $reason_id = 2; # Damaged
    } elsif ($reason eq 'missing') {
        $action_id = 1; # Deliver
        $reason_id = 1; # Missing
    } elsif ($reason eq 'new_build') {
        $action_id = 1; # Deliver
        $reason_id = 4; # New
    } elsif ($reason eq 'more') {
        if ($data->{recycling_swap} eq 'Yes') {
            # $id has to be 16 here but we want to swap it for a 12
            my $q = $c->stash->{quantities}{+CONTAINER_RECYCLING_BOX} || 1;
            $action_id = ('2::' x $q) . '1'; # Collect and Deliver
            $reason_id = ('3::' x $q) . '3'; # Change capacity
            $id = ((CONTAINER_RECYCLING_BOX . '::') x $q) . CONTAINER_RECYCLING_BIN;
            $container = $c->stash->{containers}{+CONTAINER_RECYCLING_BIN};
        } else {
            $action_id = 1; # Deliver
            $reason_id = 3; # Change capacity
        }
    } elsif ($reason eq 'change_capacity') {
        $action_id = '2::1';
        $reason_id = '3::3';
        if ($id == CONTAINER_REFUSE_140) {
            $id = CONTAINER_REFUSE_240 . '::' . CONTAINER_REFUSE_140;
        } elsif ($id == CONTAINER_REFUSE_240) {
            if ($c->stash->{quantities}{+CONTAINER_REFUSE_360}) {
                $id = CONTAINER_REFUSE_360 . '::' . CONTAINER_REFUSE_240;
            } else {
                $id = CONTAINER_REFUSE_140 . '::' . CONTAINER_REFUSE_240;
            }
        } elsif ($id == CONTAINER_PAPER_BIN) {
            $id = CONTAINER_PAPER_BIN_140 . '::' . CONTAINER_PAPER_BIN;
        }
    } else {
        # No reason, must be a bag
        $action_id = 1; # Deliver
        $reason_id = 3; # Change capacity
        $nice_reason = "Additional bag required";
    }

    if ($reason eq 'damaged' || $reason eq 'missing') {
        $data->{title} = "Request replacement $container";
    } elsif ($reason eq 'change_capacity') {
        $data->{title} = "Request exchange for $container";
    } else {
        $data->{title} = "Request new $container";
    }
    $data->{detail} = "Quantity: $quantity\n\n$address";
    $data->{detail} .= "\n\nReason: $nice_reason" if $nice_reason;

    $c->set_param('Action', join('::', ($action_id) x $quantity));
    $c->set_param('Reason', join('::', ($reason_id) x $quantity));
    if ($data->{notes_missing}) {
        $data->{detail} .= " - $data->{notes_missing}";
        $c->set_param('Notes', $data->{notes_missing});
    }
    if ($data->{notes_damaged}) {
        my $notes = $c->stash->{label_for_field}->($form, 'notes_damaged', $data->{notes_damaged});
        $data->{detail} .= " - $notes";
        $c->set_param('Notes', $notes);
    }
    $c->set_param('Container_Type', $id);
}

sub waste_munge_report_data {
    my ($self, $id, $data) = @_;

    my $c = $self->{c};

    my $booking_report;
    if ($c->get_param('original_booking_id')) {
        $booking_report = FixMyStreet::DB->resultset("Problem")->find({ id => $c->get_param('original_booking_id') });
    };
    my $address = $c->stash->{property}->{address};
    my $cfg = $self->feature('echo');
    my $service = $c->stash->{services}{$id}{service_name};
    if ($id == $cfg->{bulky_service_id}) {
        $service = 'bulky collection';
    }
    $data->{title} = "Report missed $service";
    $data->{detail} = "$data->{title}\n\n$address";
    if ($booking_report) {
        $c->set_param('Exact_Location', $booking_report->get_extra_field_value('Exact_Location'));
        $c->set_param('Original_Event_ID', $booking_report->external_id);
    }
    $c->set_param('Notes', $data->{extra_detail}) if $data->{extra_detail};
    $c->set_param('service_id', $id);
}

# Same as full cost
sub waste_get_pro_rata_cost {
    my ($self, $bins, $end) = @_;
    return $self->garden_waste_cost_pa($bins);
}

sub garden_waste_new_bin_admin_fee {
    my ($self, $new_bins) = @_;
    $new_bins ||= 0;

    my $per_new_bin_first_cost = $self->_get_cost('ggw_new_bin_first_cost');
    my $per_new_bin_cost = $self->_get_cost('ggw_new_bin_cost');

    my $cost = 0;
    if ($new_bins > 0) {
        $cost += $per_new_bin_first_cost;
        if ($new_bins > 1) {
            $cost += $per_new_bin_cost * ($new_bins - 1);
        }
    }
    return $cost;
}

=head2 waste_cc_payment_line_item_ref

This is used by the SCP role (all Kingston, Sutton requests) to provide the
reference for the credit card payment. It differs for bulky waste.

=cut

sub waste_cc_payment_line_item_ref {
    my ($self, $p) = @_;
    if ($p->category eq 'Bulky collection') {
        return $self->_waste_cc_line_item_ref($p, "BULKY", "");
    } elsif ($p->category eq 'Request new container') {
        return $self->_waste_cc_line_item_ref($p, "CCH", "");
    } else {
        return $self->_waste_cc_line_item_ref($p, "GGW", "GW Sub");
    }
}

sub waste_cc_payment_admin_fee_line_item_ref {
    my ($self, $p) = @_;
    return $self->_waste_cc_line_item_ref($p, "GGW", "GW admin charge");
}

sub _waste_cc_line_item_ref {
    my ($self, $p, $type, $str) = @_;
    my $id = $self->waste_payment_ref_council_code . "-$type-" . $p->id;
    my $len = 50 - length($id) - 1;
    if ($str) {
        $str = "-$str";
        $len -= length($str);
    }
    my $name = substr($p->name, 0, $len);
    return "$id-$name$str";
}

sub waste_cc_payment_sale_ref {
    my ($self, $p) = @_;
    return "GGW" . $p->get_extra_field_value('uprn');
}

=head2 Dashboard export

The CSV export includes all reports, including unconfirmed and hidden, and is
adapted in a few ways for Waste reports - including extra columns such as UPRN,
email/phone, payment amount and method.

=cut

# Include unconfirmed and hidden reports in CSV export
sub dashboard_export_include_all_states { 1 }

sub dashboard_export_problems_add_columns {
    my ($self, $csv) = @_;

    $csv->modify_csv_header( Detail => 'Address' );

    $csv->add_csv_columns(
        uprn => 'UPRN',
        user_email => 'User Email',
        user_phone => 'User Phone',
        payment_method => 'Payment method',
        payment_reference => 'Payment reference',
        payment => 'Payment',
        pro_rata => 'Pro rata payment',
        admin_fee => 'Admin fee',
        container => 'Subscription container',
        current_bins => 'Bin count declared',
        quantity => 'Subscription quantity',
    );

    $csv->objects_attrs({
        '+columns' => ['user.email', 'user.phone'],
        join => 'user',
    });

    $csv->csv_extra_data(sub {
        my $report = shift;

        my %fields;
        if ($csv->dbi) {
            %fields = %{$report->{extra}{_field_value} || {}};
        } else {
            my @fields = @{ $report->get_extra_fields() };
            %fields = map { $_->{name} => $_->{value} } @fields;
        }

        my $detail = $csv->dbi ? $report->{detail} : $report->detail;
        $detail =~ s/^.*?\n\n//; # Remove waste category

        return {
            detail => $detail,
            uprn => $fields{uprn},
            $csv->dbi ? (
                user_name_display => $report->{name},
                payment_reference => $fields{PaymentCode} || $report->{extra}{chequeReference} || '',
            ) : (
                user_name_display => $report->name,
                user_email => $report->user->email || '',
                user_phone => $report->user->phone || '',
                payment_reference => $fields{PaymentCode} || $report->get_extra_metadata('chequeReference') || '',
            ),
            payment_method => $fields{payment_method} || '',
            payment => $fields{payment},
            pro_rata => $fields{pro_rata},
            admin_fee => $fields{admin_fee},
            container => $fields{Subscription_Details_Containers},
            current_bins => $fields{current_containers},
            quantity => $fields{Subscription_Details_Quantity},
        };
    });
}

=head2 Bulky waste collection

SLWP looks 8 weeks ahead for collection dates, and cancels by sending an
update, not a new report. It sends the event to the backend before collecting
payment, and does not refund on cancellations. It has a hard-coded list of
property types allowed to book collections.

=cut

sub bulky_collection_window_days { 56 }

sub bulky_cancel_by_update { 1 }
sub bulky_send_before_payment { 1 }
sub bulky_show_location_field_mandatory { 1 }

sub bulky_can_refund { 0 }
sub _bulky_refund_cutoff_date { }

=head2 bulky_collection_window_start_date

K&S have an 11pm cut-off for looking to book next day collections.

=cut

sub bulky_collection_window_start_date {
    my $self = shift;
    my $now = DateTime->now( time_zone => FixMyStreet->local_time_zone );
    my $start_date = $now->clone->truncate( to => 'day' )->add( days => 1 );
    # If past 11pm, push start date one day later
    if ($now->hour >= 23) {
        $start_date->add( days => 1 );
    }
    return $start_date;
}

sub bulky_allowed_property {
    my ( $self, $property ) = @_;

    return if $property->{has_no_services};
    my $cfg = $self->feature('echo');

    my $type = $property->{type_id} || 0;
    my $valid_type = grep { $_ == $type } @{ $cfg->{bulky_address_types} || [] };
    my $domestic_farm = $type != 7 || $property->{domestic_refuse_bin};
    return $self->bulky_enabled && $valid_type && $domestic_farm;
}

sub collection_date {
    my ($self, $p) = @_;
    return $self->_bulky_date_to_dt($p->get_extra_field_value('Collection_Date'));
}

sub bulky_free_collection_available { 0 }

sub bulky_hide_later_dates { 1 }

sub _bulky_date_to_dt {
    my ($self, $date) = @_;
    $date = (split(";", $date))[0];
    my $parser = DateTime::Format::Strptime->new( pattern => '%FT%T', time_zone => FixMyStreet->local_time_zone);
    my $dt = $parser->parse_datetime($date);
    return $dt ? $dt->truncate( to => 'day' ) : undef;
}

=head2 Sending to Echo

We use the reserved slot GUID and reference,
and the provided date/location information.
Items are sent through with their notes as individual entries

=cut

sub waste_munge_bulky_data {
    my ($self, $data) = @_;

    my $c = $self->{c};
    my ($date, $ref, $expiry) = split(";", $data->{chosen_date});

    my $guid_key = $self->council_url . ":echo:bulky_event_guid:" . $c->stash->{property}->{id};
    $data->{extra_GUID} = $self->{c}->session->{$guid_key};
    $data->{extra_reservation} = $ref;

    $data->{title} = "Bulky goods collection";
    $data->{detail} = "Address: " . $c->stash->{property}->{address};
    $data->{category} = "Bulky collection";
    $data->{extra_Collection_Date} = $date;
    $data->{extra_Exact_Location} = $data->{location};

    my $first_date = $self->{c}->session->{first_date_returned};
    $first_date = DateTime::Format::W3CDTF->parse_datetime($first_date);
    my $dt = DateTime::Format::W3CDTF->parse_datetime($date);
    $data->{'extra_First_Date_Returned_to_Customer'} = $first_date->strftime("%d/%m/%Y");
    $data->{'extra_Customer_Selected_Date_Beyond_SLA?'} = $dt > $first_date ? 1 : 0;

    my @items_list = @{ $self->bulky_items_master_list };
    my %items = map { $_->{name} => $_->{bartec_id} } @items_list;

    my @notes;
    my @ids;
    my @photos;

    my $max = $self->bulky_items_maximum;
    for (1..$max) {
        if (my $item = $data->{"item_$_"}) {
            push @notes, $data->{"item_notes_$_"} || '';
            push @ids, $items{$item};
            push @photos, $data->{"item_photos_$_"} || '';
        };
    }
    $data->{extra_Bulky_Collection_Notes} = join("::", @notes);
    $data->{extra_Bulky_Collection_Bulky_Items} = join("::", @ids);
    $data->{extra_Image} = join("::", @photos);
    $self->bulky_total_cost($data);
}

sub waste_reconstruct_bulky_data {
    my ($self, $p) = @_;

    my $saved_data = {
        "chosen_date" => $p->get_extra_field_value('Collection_Date'),
        "location" => $p->get_extra_field_value('Exact_Location'),
        "location_photo" => $p->get_extra_metadata("location_photo"),
    };

    my @fields = split /::/, $p->get_extra_field_value('Bulky_Collection_Bulky_Items');
    my @notes = split /::/, $p->get_extra_field_value('Bulky_Collection_Notes');
    for my $id (1..@fields) {
        $saved_data->{"item_$id"} = $p->get_extra_metadata("item_$id");
        $saved_data->{"item_notes_$id"} = $notes[$id-1];
        $saved_data->{"item_photo_$id"} = $p->get_extra_metadata("item_photo_$id");
    }

    $saved_data->{name} = $p->name;
    $saved_data->{email} = $p->user->email;
    $saved_data->{phone} = $p->phone_waste;

    return $saved_data;
}

=head2 suppress_report_sent_email

For Bulky Waste reports, we want to send the email after payment has been confirmed, so we
suppress the email here.

=cut

sub suppress_report_sent_email {
    my ($self, $report) = @_;

    if ($report->cobrand_data eq 'waste' && $report->category eq 'Bulky collection') {
        return 1;
    }

    return 0;
}

sub bulky_location_photo_prompt {
    'Help us by attaching a photo of where the items will be left for collection.';
}

1;
