use utf8;
use JSON::MaybeXS;
use Path::Tiny;
use Storable qw(dclone);
use Test::MockModule;
use Test::MockTime qw(:all);
use FixMyStreet::TestMech;
use FixMyStreet::Script::Reports;
use CGI::Simple;

FixMyStreet::App->log->disable('info');
END { FixMyStreet::App->log->enable('info'); }

my $mech = FixMyStreet::TestMech->new;

my $bin_data = decode_json(path(__FILE__)->sibling('waste_4443082.json')->slurp_utf8);
my $bin_140_data = decode_json(path(__FILE__)->sibling('waste_4443082_140.json')->slurp_utf8);
my $kerbside_bag_data = decode_json(path(__FILE__)->sibling('waste_4471550.json')->slurp_utf8);
my $above_shop_data = decode_json(path(__FILE__)->sibling('waste_4499005.json')->slurp_utf8);

my $params = {
    send_method => 'Open311',
    api_key => 'KEY',
    endpoint => 'endpoint',
    jurisdiction => 'home',
    can_be_devolved => 1,
};
my $body = $mech->create_body_ok(2498, 'Sutton Council', $params, {
    cobrand => 'sutton',
    wasteworks_config => { request_timeframe => '20 working days' }
});
my $kingston = $mech->create_body_ok(2480, 'Kingston Council', $params, { cobrand => 'kingston' });
my $user = $mech->create_user_ok('test@example.net', name => 'Normal User');
my $staff = $mech->create_user_ok('staff@example.net', name => 'Staff User', from_body => $kingston->id);
$staff->user_body_permissions->create({ body => $kingston, permission_type => 'report_edit' });

sub create_contact {
    my ($params, $group, @extra) = @_;
    my $contact = $mech->create_contact_ok(body => $body, %$params, group => [$group]);
    $contact->set_extra_metadata( type => 'waste' );
    $contact->set_extra_fields(
        { code => 'uprn', required => 1, automated => 'hidden_field' },
        @extra,
    );
    $contact->update;
}

create_contact({ category => 'Report missed collection', email => 'missed' }, 'Waste',
    { code => 'service_id', required => 1, automated => 'hidden_field' },
    { code => 'fixmystreet_id', required => 1, automated => 'hidden_field' },
);
create_contact({ category => 'Request new container', email => '1635' }, 'Waste',
    { code => 'uprn', required => 1, automated => 'hidden_field' },
    { code => 'fixmystreet_id', required => 1, automated => 'hidden_field' },
    { code => 'Container_Type', required => 1, automated => 'hidden_field' },
    { code => 'Action', required => 1, automated => 'hidden_field' },
    { code => 'Reason', required => 1, automated => 'hidden_field' },
    { code => 'LastPayMethod', required => 0, automated => 'hidden_field' },
    { code => 'PaymentCode', required => 0, automated => 'hidden_field' },
    { code => 'payment_method', required => 0, automated => 'hidden_field' },
    { code => 'payment', required => 0, automated => 'hidden_field' },
);

my $sent_params;

FixMyStreet::override_config {
    ALLOWED_COBRANDS => 'sutton',
    MAPIT_URL => 'http://mapit.uk/',
    COBRAND_FEATURES => {
        echo => { sutton => {
            url => 'http://example.org/',
        } },
        waste => { sutton => 1 },
        echo => { sutton => { bulky_service_id => 413 }},
        payment_gateway => { sutton => {
            cc_url => 'http://example.com',
            request_replace_cost => 500,
            request_change_cost => 1500,
        } },
    },
    STAGING_FLAGS => {
        send_reports => 1,
    },
}, sub {
    my ($e) = shared_echo_mocks();
    my ($scp) = shared_scp_mocks();

    subtest 'Address lookup' => sub {
        set_fixed_time('2022-09-10T12:00:00Z');
        $mech->get_ok('/waste/12345');
        $mech->content_contains('2 Example Street, Sutton');
        $mech->content_contains('Every Friday fortnightly');
        $mech->content_contains('Friday, 2nd September');
        $mech->content_contains('Report a mixed recycling collection as missed');
    };
    subtest 'In progress collection' => sub {
        $e->mock('GetTasks', sub { [ {
            Ref => { Value => { anyType => [ 17430692, 8287 ] } },
            State => { Name => 'Completed' },
            CompletedDate => { DateTime => '2022-09-09T16:00:00Z' }
        }, {
            Ref => { Value => { anyType => [ 17510905, 8287 ] } },
            State => { Name => 'Allocated' },
            CompletedDate => undef
        } ] });
        set_fixed_time('2022-09-09T16:30:00Z');
        $mech->get_ok('/waste/12345');
        $mech->content_like(qr/Friday, 9th September\s+\(this collection has been adjusted from its usual time\)\s+\(In progress\)/);
        $mech->content_lacks(', at  4:00pm');
        $mech->content_lacks('Report a mixed recycling collection as missed');
        $mech->content_lacks('Report a non-recyclable refuse collection as missed');
        set_fixed_time('2022-09-09T19:00:00Z');
        $mech->get_ok('/waste/12345');
        $mech->content_contains(', at  4:00pm');
        $mech->content_contains('Report a mixed recycling collection as missed');
        $mech->content_contains('Report a non-recyclable refuse collection as missed');
        $e->mock('GetTasks', sub { [] });
    };
    subtest 'Request a new bin' => sub {
        $mech->follow_link_ok( { text => 'Request a bin, box, caddy or bags' } );
		# 19 (1), 24 (1), 16 (1), 1 (1)
        # missing, new_build, more
        $mech->content_contains('The Council has continued to provide waste and recycling containers free for as long as possible', 'Intro text included');
        $mech->content_contains('You can request a larger container if you meet the following criteria', 'Divider intro text included for container sizes');
        $mech->submit_form_ok({ with_fields => { 'container-choice' => 19 }});
        $mech->submit_form_ok({ with_fields => { 'request_reason' => 'damaged' }});
        $mech->submit_form_ok({ with_fields => { name => 'Bob Marge', email => $user->email }});
        $mech->content_contains('Continue to payment');

        my $mech2 = $mech->clone;
        $mech2->submit_form_ok({ with_fields => { process => 'summary' } });
        is $mech2->res->previous->code, 302, 'payments issues a redirect';
        is $mech2->res->previous->header('Location'), "http://example.org/faq", "redirects to payment gateway";
        is $sent_params->{items}[0]{amount}, 500;

        my ( $token, $report, $report_id ) = get_report_from_redirect( $sent_params->{returnUrl} );
        $mech->get_ok("/waste/pay_complete/$report_id/$token");

        $mech->content_contains('request has been sent');
        $mech->content_contains('Containers typically arrive within 20 working days');

        is $report->get_extra_field_value('uprn'), 1000000002;
        is $report->detail, "Quantity: 1\n\n2 Example Street, Sutton, SM1 1AA\n\nReason: Damaged";
        is $report->category, 'Request new container';
        is $report->title, 'Request replacement Paper and Cardboard Green Wheelie Bin (240L)';
        is $report->get_extra_field_value('payment'), 500, 'correct payment';
        is $report->get_extra_field_value('payment_method'), 'credit_card', 'correct payment method on report';
        is $report->get_extra_field_value('Container_Type'), 19, 'correct bin type';
        is $report->get_extra_field_value('Action'), 3, 'correct container request action';
        is $report->state, 'unconfirmed', 'report not confirmed';
        is $report->get_extra_metadata('scpReference'), '12345', 'correct scp reference on report';

        FixMyStreet::Script::Reports::send();
        my $email = $mech->get_text_body_from_email;
        like $email, qr/please allow up to 20 working days/;
    };
    subtest 'Request a larger bin than current' => sub {
        $mech->get_ok('/waste/12345/request');
        $mech->submit_form_ok({ with_fields => { 'container-choice' => 2 }});
        $mech->submit_form_ok({ with_fields => { name => 'Bob Marge', email => $user->email }});
        $mech->content_contains('Continue to payment');

        my $mech2 = $mech->clone;
        $mech2->submit_form_ok({ with_fields => { process => 'summary' } });
        is $mech2->res->previous->code, 302, 'payments issues a redirect';
        is $mech2->res->previous->header('Location'), "http://example.org/faq", "redirects to payment gateway";
        is $sent_params->{items}[0]{amount}, 1500;

        my ( $token, $report, $report_id ) = get_report_from_redirect( $sent_params->{returnUrl} );
        $mech->get_ok("/waste/pay_complete/$report_id/$token");
        $mech->content_contains('request has been sent');
        $mech->content_contains('Containers typically arrive within 20 working days');

        is $report->get_extra_field_value('uprn'), 1000000002;
        is $report->title, 'Request exchange for Larger Brown General Waste Wheelie Bin (240L)';
        is $report->get_extra_field_value('payment'), 1500, 'correct payment';
        is $report->get_extra_field_value('Container_Type'), '1::2', 'correct bin type';
        is $report->get_extra_field_value('Action'), '2::1', 'correct container request action';
        is $report->get_extra_field_value('Reason'), '3::3', 'correct container request reason';
    };
    subtest 'Request a paper bin when having a 140L' => sub {
        $e->mock('GetServiceUnitsForObject', sub { $bin_140_data });
        $mech->get_ok('/waste/12345/request');
        $mech->submit_form_ok({ with_fields => { 'container-choice' => 19 }});
        $mech->submit_form_ok({ with_fields => { name => 'Bob Marge', email => $user->email }});
        $mech->content_contains('Continue to payment');

        my $mech2 = $mech->clone;
        $mech2->submit_form_ok({ with_fields => { process => 'summary' } });
        is $mech2->res->previous->code, 302, 'payments issues a redirect';
        is $mech2->res->previous->header('Location'), "http://example.org/faq", "redirects to payment gateway";
        is $sent_params->{items}[0]{amount}, 1500;

        my ( $token, $report, $report_id ) = get_report_from_redirect( $sent_params->{returnUrl} );
        $mech->get_ok("/waste/pay_complete/$report_id/$token");
        $mech->content_contains('request has been sent');
        $mech->content_contains('Containers typically arrive within 20 working days');

        is $report->get_extra_field_value('uprn'), 1000000002;
        is $report->title, 'Request exchange for Paper and Cardboard Green Wheelie Bin (240L)';
        is $report->get_extra_field_value('payment'), 1500, 'correct payment';
        is $report->get_extra_field_value('Container_Type'), '36::19', 'correct bin type';
        is $report->get_extra_field_value('Action'), '2::1', 'correct container request action';
        is $report->get_extra_field_value('Reason'), '3::3', 'correct container request reason';
        $e->mock('GetServiceUnitsForObject', sub { $bin_data });
    };
    subtest 'Report a new recycling raises a bin delivery request' => sub {
        $mech->log_in_ok($user->email);
        $mech->get_ok('/waste/12345/request');
        $mech->submit_form_ok({ with_fields => { 'container-choice' => 16 } });
        $mech->submit_form_ok({ with_fields => { 'request_reason' => 'missing' }});
        $mech->submit_form_ok({ with_fields => { name => 'Bob Marge', email => $user->email }});
        $mech->submit_form_ok({ with_fields => { process => 'summary' } });
        $mech->content_contains('request has been sent');
        my $report = FixMyStreet::DB->resultset("Problem")->search(undef, { order_by => { -desc => 'id' } })->first;
        is $report->get_extra_field_value('uprn'), 1000000002;
        is $report->detail, "Quantity: 1\n\n2 Example Street, Sutton, SM1 1AA\n\nReason: Missing";
        is $report->title, 'Request replacement Mixed Recycling Green Box (55L)';
    };

    subtest 'Report missed collection' => sub {
        $mech->get_ok('/waste/12345/report');
		$mech->content_contains('Food waste');
		$mech->content_contains('Mixed recycling');
		$mech->content_contains('Non-recyclable Refuse');
		$mech->content_lacks('Paper and card');

        $mech->submit_form_ok({ with_fields => { 'service-2239' => 1 } });
        $mech->submit_form_ok({ with_fields => { name => 'Bob Marge', email => $user->email }});
        $mech->submit_form_ok({ with_fields => { process => 'summary' } });
        $mech->content_contains('collection has been reported');
        my $report = FixMyStreet::DB->resultset("Problem")->search(undef, { order_by => { -desc => 'id' } })->first;
        is $report->get_extra_field_value('uprn'), 1000000002;
        is $report->detail, "Report missed Food waste\n\n2 Example Street, Sutton, SM1 1AA";
        is $report->title, 'Report missed Food waste';
    };
    subtest 'No reporting/requesting if open request' => sub {
        $mech->get_ok('/waste/12345');
        $mech->content_contains('Report a mixed recycling collection as missed');
        $mech->content_lacks('Request a mixed recycling container');

        $e->mock('GetEventsForObject', sub { [ {
            # Request
            EventTypeId => 1635,
            Data => { ExtensibleDatum => [
                { Value => 2, DatatypeName => 'Source' },
                {
                    ChildData => { ExtensibleDatum => [
                        { Value => 1, DatatypeName => 'Action' },
                        { Value => 16, DatatypeName => 'Container Type' },
                    ] },
                },
            ] },
        } ] });
        $mech->get_ok('/waste/12345');
        $mech->content_contains('A mixed recycling container request has been made');
        $mech->content_contains('Report a mixed recycling collection as missed');
        $mech->get_ok('/waste/12345/request');
        $mech->content_like(qr/name="container-choice" value="16"\s+disabled/s); # green

        $e->mock('GetEventsForObject', sub { [ {
            # Request
            EventTypeId => 1635,
            Data => { ExtensibleDatum => [
                { Value => 2, DatatypeName => 'Source' },
                {
                    ChildData => { ExtensibleDatum => [
                        { Value => 1, DatatypeName => 'Action' },
                        { Value => 23, DatatypeName => 'Container Type' },
                    ] },
                },
            ] },
        } ] });
        $mech->get_ok('/waste/12345');
        $mech->content_contains('A food waste container request has been made');
        $mech->get_ok('/waste/12345/request');
        $mech->content_like(qr/name="container-choice" value="23"\s+disabled/s); # indoor
        $mech->content_like(qr/name="container-choice" value="24"\s*>/s); # outdoor

        $e->mock('GetEventsForObject', sub { [ {
            EventTypeId => 1566,
            EventDate => { DateTime => "2022-09-10T17:00:00Z" },
            ServiceId => 408,
            Data => { ExtensibleDatum => [
                { Value => 1, DatatypeName => 'Container Mix' },
            ] },
        } ] });
        $mech->get_ok('/waste/12345');
        $mech->content_contains('A mixed recycling collection has been reported as missed');
        $mech->content_lacks('Request a mixed recycling container');

        $e->mock('GetEventsForObject', sub { [ {
            EventTypeId => 1566,
            EventDate => { DateTime => "2022-09-10T17:00:00Z" },
            ServiceId => 408,
            Data => { ExtensibleDatum => {
                Value => 1, DatatypeName => 'Paper'
            } },
        } ] });
        $mech->get_ok('/waste/12345');
        $mech->content_contains('A paper and card collection has been reported as missed');

        $e->mock('GetEventsForObject', sub { [] }); # reset
    };
    subtest 'No reporting if open request on service unit' => sub {
        $e->mock('GetEventsForObject', sub {
            my ($self, $type, $id) = @_;
            return [] if $type eq 'PointAddress' || $id == 1002;
            is $id, 1001; # recycling service unit
            return [ {
                EventTypeId => 1566,
                EventDate => { DateTime => "2022-09-10T17:00:00Z" },
                ServiceId => 408,
                Data => { ExtensibleDatum => [
                    { Value => 1, DatatypeName => 'Container Mix' },
                ] },
            } ]
        });
        $mech->get_ok('/waste/12345');
        $mech->content_contains('A mixed recycling collection has been reported as missed');
        $e->mock('GetEventsForObject', sub { [] }); # reset
    };
    subtest 'No requesting if open request of different size' => sub {
        $mech->get_ok('/waste/12345/request');
        $mech->content_unlike(qr/name="container-choice" value="1"[^>]+disabled/s);

        $e->mock('GetEventsForObject', sub { [ {
            # Request
            EventTypeId => 1635,
            Data => { ExtensibleDatum => [
                { Value => 2, DatatypeName => 'Source' },
                {
                    ChildData => { ExtensibleDatum => [
                        { Value => 1, DatatypeName => 'Action' },
                        { Value => 1, DatatypeName => 'Container Type' },
                    ] },
                },
            ] },
        } ] });
        $mech->get_ok('/waste/12345/request');
        $mech->content_like(qr/name="container-choice" value="1"[^>]+disabled/s);

        $e->mock('GetEventsForObject', sub { [ {
            # Request
            EventTypeId => 1635,
            Data => { ExtensibleDatum => [
                { Value => 2, DatatypeName => 'Source' },
                {
                    ChildData => { ExtensibleDatum => [
                        { Value => 1, DatatypeName => 'Action' },
                        { Value => 2, DatatypeName => 'Container Type' },
                    ] },
                },
            ] },
        } ] });
        $mech->get_ok('/waste/12345/request');
        $mech->content_like(qr/name="container-choice" value="1"[^>]+disabled/s); # still disabled

        $e->mock('GetEventsForObject', sub { [] }); # reset
    };


    $e->mock('GetServiceUnitsForObject', sub { $kerbside_bag_data });
    subtest 'No requesting a red stripe bag' => sub {
        $mech->get_ok('/waste/12345/request');
        $mech->content_lacks('"container-choice" value="6"');
    };
    subtest 'Fortnightly collection can request a blue stripe bag' => sub {
        $mech->get_ok('/waste/12345/request');
        $mech->submit_form_ok({ with_fields => { 'container-choice' => 18 }});
        $mech->submit_form_ok({ with_fields => { name => 'Bob Marge', email => $user->email }});
        $mech->submit_form_ok({ with_fields => { process => 'summary' } });
        $mech->content_contains('request has been sent');
        my $report = FixMyStreet::DB->resultset("Problem")->search(undef, { order_by => { -desc => 'id' } })->first;
        is $report->get_extra_field_value('uprn'), 1000000002;
        is $report->detail, "Quantity: 1\n\n2 Example Street, Sutton, SM1 1AA\n\nReason: Additional bag required";
        is $report->category, 'Request new container';
        is $report->title, 'Request new Mixed Recycling Blue Striped Bag';
    };
    subtest 'Weekly collection cannot request a blue stripe bag' => sub {
        $e->mock('GetServiceUnitsForObject', sub { $above_shop_data });
        $mech->get_ok('/waste/12345/request');
        $mech->content_lacks('"container-choice" value="18"');
        $e->mock('GetServiceUnitsForObject', sub { $bin_data });
    };

    subtest 'Fetching property without services give Sutton specific error' => sub {
        $e->mock('GetServiceUnitsForObject', sub { [] });
        $mech->get_ok('/waste/12345/');
        $mech->content_contains('Oh no! Something has gone wrong');
        $e->mock('GetServiceUnitsForObject', sub { $bin_data });
    };

    subtest 'Okay fetching property with two of the same task type' => sub {
        my @dupe = @$bin_data;
        push @dupe, dclone($dupe[0]);
        # Give the new entry a different ID and task ref
        $dupe[$#dupe]->{ServiceTasks}{ServiceTask}[0]{Id} = 4001;
        $dupe[$#dupe]->{ServiceTasks}{ServiceTask}[0]{ServiceTaskSchedules}{ServiceTaskSchedule}{LastInstance}{Ref}{Value}{anyType}[1] = 8281;
        $e->mock('GetServiceUnitsForObject', sub { \@dupe });
        $e->mock('GetTasks', sub { [ {
            Ref => { Value => { anyType => [ 22239416, 8280 ] } },
            State => { Name => 'Completed' },
            CompletedDate => { DateTime => '2022-09-09T16:00:00Z' }
        }, {
            Ref => { Value => { anyType => [ 22239416, 8281 ] } },
            State => { Name => 'Outstanding' },
            CompletedDate => undef
        } ] });
        $mech->get_ok('/waste/12345');
        $mech->content_lacks('assisted collection'); # For below, while we're here
        $e->mock('GetTasks', sub { [] });
        $e->mock('GetServiceUnitsForObject', sub { $bin_data });
    };

    subtest 'Assisted collection display for staff' => sub {
        $mech->log_in_ok($staff->email);
        $mech->get_ok('/waste/12345');
        $mech->content_contains('not set up for assisted collection');
        my $dupe = dclone($bin_data);
        # Give the entry an assisted collection
        $dupe->[0]{Data}{ExtensibleDatum}{DatatypeName} = 'Assisted Collection';
        $dupe->[0]{Data}{ExtensibleDatum}{Value} = 1;
        $e->mock('GetServiceUnitsForObject', sub { $dupe });
        $mech->get_ok('/waste/12345');
        $mech->content_contains('is set up for assisted collection');
        $e->mock('GetServiceUnitsForObject', sub { $bin_data });
    };
};

sub get_report_from_redirect {
    my $url = shift;

    my ($report_id, $token) = ( $url =~ m#/(\d+)/([^/]+)$# );
    my $new_report = FixMyStreet::DB->resultset('Problem')->find( {
        id => $report_id,
    });

    return undef unless $new_report->get_extra_metadata('redirect_id') eq $token;
    return ($token, $new_report, $report_id);
}

sub shared_echo_mocks {
    my $e = Test::MockModule->new('Integrations::Echo');
    $e->mock('GetPointAddress', sub {
        return {
            Id => 12345,
            SharedRef => { Value => { anyType => '1000000002' } },
            PointType => 'PointAddress',
            PointAddressType => { Name => 'House' },
            Coordinates => { GeoPoint => { Latitude => 51.359723, Longitude => -0.193146 } },
            Description => '2 Example Street, Sutton, SM1 1AA',
        };
    });
    $e->mock('GetServiceUnitsForObject', sub { $bin_data });
    $e->mock('GetEventsForObject', sub { [] });
    $e->mock('GetEvent', sub { {} });
    $e->mock('GetTasks', sub { [] });
    $e->mock( 'CancelReservedSlotsForEvent', sub {
        my (undef, $guid) = @_;
        ok $guid, 'non-nil GUID passed to CancelReservedSlotsForEvent';
    } );
    return $e;
}

sub shared_scp_mocks {
    my $pay = Test::MockModule->new('Integrations::SCP');

    $pay->mock(pay => sub {
        my $self = shift;
        $sent_params = shift;
        return {
            transactionState => 'IN_PROGRESS',
            scpReference => '12345',
            invokeResult => {
                status => 'SUCCESS',
                redirectUrl => 'http://example.org/faq'
            }
        };
    });
    $pay->mock(query => sub {
        my $self = shift;
        $sent_params = shift;
        return {
            transactionState => 'COMPLETE',
            paymentResult => {
                status => 'SUCCESS',
                paymentDetails => {
                    paymentHeader => {
                        uniqueTranId => 54321
                    }
                }
            }
        };
    });
    return $pay;
}

done_testing;
