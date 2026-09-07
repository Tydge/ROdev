package Economy::Trade;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Economy::Inventory;

# Pure protocol controller. No asset mutation: completion requires the server
# event, a fresh authoritative zeny event, and matching inventory/cart snapshots.
sub new {
    my ($class, %a) = @_;
    die 'role must be seller|buyer' unless ($a{role}||'') =~ /^(seller|buyer)$/;
    die 'policy required' unless $a{policy};
    return bless { %a, state=>'idle', timeout=>$a{timeout}||30, cooldown=>$a{cooldown}||15,
        now_fn=>$a{now_fn}||sub {time}, seen=>{}, sequence=>0 }, $class;
}
sub state { $_[0]{state} }
sub counterpart { $_[0]{counterpart}||'' }
sub nonce { $_[0]{nonce}||'' }
sub active { $_[0]{state} ne 'idle' }
sub _now { $_[0]{now_fn}->() }
sub _enter { $_[0]{state}=$_[1]; $_[0]{deadline}=$_[0]->_now()+$_[0]{timeout} }
sub _log {
    my ($s,$message,@actions)=@_;
    return [{type=>'log',msg=>'[TRADE] tx='.$s->nonce.' role='.$s->{role}.' self='.($s->{self_name}||'?').' peer='.$s->counterpart.' '.$message},@actions];
}
sub _reset {
    my ($s)=@_;
    delete @$s{qw(nonce counterpart batch total before zeny_version sent offered own_paid peer_verified complete_seen)};
    $s->{state}='idle';
}
sub _new_nonce {
    my ($s)=@_;
    return $s->{nonce_fn}->() if $s->{nonce_fn};
    return substr(sha256_hex(join(':',$$, $s->_now(), ++$s->{sequence}, rand())),0,24);
}
sub _pm { my ($s,$msg)=@_; return {type=>'send_pm',to=>$s->counterpart,msg=>$msg} }
sub abort {
    my ($s,$reason)=@_;
    return [] if $s->{state} =~ /^(idle|done|cancelling|rollback|halted)$/;
    $s->{reason}=$reason;
    # Even before engagement an incoming/outgoing request may exist on server.
    $s->_enter('cancelling');
    return $s->_log("cancel reason=$reason", {type=>'cancel_deal'});
}
sub on_disconnected {
    my ($s)=@_;
    return [] unless $s->active;
    if ($s->{state} eq 'done' && ($s->{role} eq 'buyer' || $s->{peer_verified})) {
        $s->_reset; return $s->_log('closed verified session before disconnect');
    }
    $s->_enter('halted');
    return $s->_log('DISCONNECTED: stop; relog assets must be reconciled before reset');
}
# Explicit recovery after reconnect: rebuild only from a fresh server wallet
# and inventory snapshot. Never replay a prior commit or manufacture a success.
sub reconcile {
    my ($s,$c)=@_;
    return $s->_log('reconcile requires halted state and fresh server assets') unless
        $s->{state} eq 'halted' && !$c->{deal_active} && $c->{snapshot} &&
        defined($c->{server_zeny}) && $c->{snapshot}{zeny}==$c->{server_zeny} &&
        ($c->{zeny_version}||0)>($s->{zeny_version}||0);
    my $result='no_engaged_trade';
    if ($s->{before}) {
        if (Economy::Inventory::matches($s->{before},$c->{snapshot},$s->{batch},$s->{total},$s->{role},0)) {$result='rollback';}
        elsif (Economy::Inventory::matches($s->{before},$c->{snapshot},$s->{batch},$s->{total},$s->{role},1)) {$result='asset_transfer';}
        else {return $s->_log('RECONCILIATION_REQUIRED: assets differ; no reset');}
    }
    my $out=$s->_log("RECONCILED snapshot=$result; rebuild from actual inventory, no prior payment replay");
    $s->_reset;
    return $out;
}
sub on_cancelled {
    my ($s)=@_;
    return [] unless $s->active;
    $s->_enter('rollback');
    return $s->_log('server cancelled; awaiting rollback snapshot');
}
sub on_error { $_[0]->abort('SERVER_ERROR_'.($_[1]//'unknown')) }
sub on_pm {
    my ($s,$from,$msg,$ctx)=@_;
    $ctx ||= {};
    $s->{self_name}=$ctx->{self_name} if $ctx->{self_name};
    return [] unless defined $from && defined $msg && length($msg)<=240;
    my @p=split /\s+/, $msg;
    if ($s->{role} eq 'seller') {
        return [] unless $from eq ($s->{merchant}||'') && @p>=2 && $p[1] eq $s->nonce;
        if ($p[0] eq 'VERIFIED' && $s->{state} =~ /^(verifying|done)$/) {
            $s->{peer_verified}=1; return [];
        }
        return [] unless $p[0] eq 'READY' && @p==3 && $s->{state} eq 'wait_ready';
        return $s->abort('WRONG_TOTAL') unless $p[2] =~ /^\d+$/ && $p[2]==$s->{total};
        return $s->abort('PEER_UNAVAILABLE') unless $ctx->{peer_near} && $ctx->{safe};
        $s->_enter('initiating');
        return $s->_log('READY total='.$s->{total},{type=>'initiate_deal',name=>$from});
    }
    return [] unless ($s->{sellers}||{})->{$from};
    if ($p[0] eq 'SELL_REQUEST' && @p==3 && $p[1] =~ /^[a-f0-9]{8,64}$/ && $p[2] =~ /^(?:[1-9]|10)$/) {
        return [] unless $s->{state} eq 'idle' && $ctx->{safe} && $ctx->{peer_near};
        my $key="$from:$p[1]";
        return [] if $s->{seen}{$key};
        # Bounded replay cache; expired sessions cannot match a new active nonce.
        delete $s->{seen}{$_} for grep {$s->{seen}{$_} < $s->_now()-86400} keys %{$s->{seen}};
        return [] if keys(%{$s->{seen}})>=10000;
        $s->{seen}{$key}=$s->_now();
        @$s{qw(nonce counterpart count)}=($p[1],$from,0+$p[2]);
        $s->{batch}=[]; $s->{total}=0;
        $s->_enter('collecting');
        return $s->_log('collecting entries='.$s->{count});
    }
    return [] unless $s->{state} eq 'collecting' && $from eq $s->counterpart &&
        @p==6 && $p[0] eq 'SELL_ITEM' && $p[1] eq $s->nonce;
    return $s->abort('INVALID_MANIFEST') unless $p[2] =~ /^\d+$/ && $p[2]==@{$s->{batch}} &&
        $p[3] =~ /^\d+$/ && $p[4] =~ /^\d+$/ && $p[4]>0 && $p[4]<=30000 && $p[5] =~ /^[a-f0-9]{64}$/;
    my $price=$s->{policy}->price($p[3]);
    return $s->abort('UNPRICED_ITEM') unless defined $price;
    push @{$s->{batch}}, {nameID=>0+$p[3],amount=>0+$p[4],sig=>$p[5]};
    $s->{total}+=$price*$p[4];
    return $s->abort('TOTAL_OVERFLOW') if $s->{total}>1_000_000_000;
    return [] if @{$s->{batch}} < $s->{count};
    my $error=$s->{policy}->capacity($s->{batch},$s->{total},$ctx->{capacity}||{});
    return $s->abort($error||'PEER_UNAVAILABLE') if $error || !$ctx->{safe} || !$ctx->{peer_near};
    $s->_enter('ready_sent');
    return $s->_log('quote total='.$s->{total},$s->_pm('READY '.$s->nonce.' '.$s->{total}));
}
sub on_incoming_deal {
    my ($s,$name,$ctx)=@_;
    return [{type=>'reject_request'}] unless $s->{role} eq 'buyer' && $s->{state} eq 'ready_sent' &&
        $name eq $s->counterpart && $ctx->{peer_near} && $ctx->{safe};
    $s->_enter('accepting');
    return $s->_log('accepting',{type=>'accept_deal'});
}
sub on_engaged {
    my ($s,$name,$ctx)=@_;
    return $s->abort('UNEXPECTED_PEER') unless $name eq $s->counterpart &&
        $s->{state} eq ($s->{role} eq 'seller' ? 'initiating' : 'accepting');
    return $s->abort('ASSETS_NOT_READY') unless $ctx->{snapshot};
    $s->{self_name}=$ctx->{self_name} if $ctx->{self_name};
    $s->{before}=$ctx->{snapshot}; $s->{zeny_version}=$ctx->{zeny_version}||0;
    $s->{sent}=0; $s->{offered}=[]; $s->{own_paid}=0;
    $s->_enter('engaged');
    return $s->{role} eq 'seller' ? $s->_add_next : $s->_log('engaged');
}
sub _add_next {
    my ($s)=@_;
    return [] if $s->{sent}>=@{$s->{batch}};
    my $item=$s->{batch}[$s->{sent}];
    return $s->_log("offer nameID=$item->{nameID} amount=$item->{amount} unit=".$s->{policy}->price($item->{nameID}),
        {type=>'add_item',%$item});
}
sub on_own_item {
    my ($s,$slot,$sig,$amount)=@_;
    return [] unless $s->{role} eq 'seller' && $s->{state} eq 'engaged';
    my $e=$s->{batch}[$s->{sent}];
    return $s->abort('OWN_ITEM_ACK_MISMATCH') unless $e && $e->{slot}==$slot && $e->{sig} eq $sig && $e->{amount}==$amount;
    $s->{sent}++; $s->_enter('engaged');
    return $s->_add_next;
}
sub on_other_item {
    my ($s,$item)=@_;
    return [] unless $s->{state} =~ /^(engaged|paying|quoted|committing)$/;
    return $s->abort('UNEXPECTED_ITEM') if $s->{role} eq 'seller' || $s->{state} ne 'engaged';
    my $e=$s->{batch}[scalar @{$s->{offered}}];
    return $s->abort('OFFER_CHANGED') unless $e && $s->{policy}->eligible($item,1) &&
        $e->{nameID}==$item->{nameID} && $e->{amount}==$item->{amount} && $e->{sig} eq Economy::Inventory::signature($item);
    push @{$s->{offered}}, {%$item};
    return $s->_log('received offer nameID='.$item->{nameID}.' amount='.$item->{amount}.' unit='.$s->{policy}->price($item->{nameID}).' sig='.$e->{sig});
}
sub on_own_zeny { return [] } # rAthena acknowledges lock with index 0, not adding Zeny.
sub on_other_finalized { return [] } # tick validates a fresh complete context before any commit
sub on_complete {
    my ($s)=@_;
    return [] if $s->{state} eq 'verifying' || $s->{state} eq 'done';
    return $s->abort('UNEXPECTED_COMPLETE') unless $s->{state} eq 'committing' || $s->{state} eq 'cancelling';
    $s->{complete_seen}=1; $s->_enter('verifying');
    return $s->_log('server complete; verifying assets');
}
sub tick {
    my ($s,%c)=@_;
    my $now=$c{now}//$s->_now();
    $s->{self_name}=$c{self_name} if $c{self_name};
    return [] if $s->{state} eq 'halted';
    if ($s->{state} eq 'done') {
        return [] if $now<$s->{ended_at}+$s->{cooldown};
        if ($s->{role} eq 'seller' && !$s->{peer_verified}) {
            if ($now>$s->{deadline}) { $s->_enter('halted'); return $s->_log('PEER_VERIFICATION_TIMEOUT: next batch stopped'); }
            return [];
        }
        $s->_reset;
    }
    if ($s->{state} eq 'rollback') {
        if (!$c{deal_active} && (!$s->{before} || Economy::Inventory::matches($s->{before},$c{snapshot},$s->{batch},$s->{total},$s->{role},0))) {
            $s->{ended_at}=$now; $s->{peer_verified}=1; $s->_enter('done');
            return $s->_log('rollback verified; deferred until cooldown');
        }
    }
    if ($s->{state} eq 'verifying') {
        if (($c{zeny_version}||0)>$s->{zeny_version} && defined($c{server_zeny}) &&
            $c{snapshot} && $c{snapshot}{zeny}==$c{server_zeny} &&
            Economy::Inventory::matches($s->{before},$c{snapshot},$s->{batch},$s->{total},$s->{role},1)) {
            $s->{ended_at}=$now; $s->_enter('done');
            return $s->_log('VERIFIED total='.$s->{total}.' zeny_before='.$s->{before}{zeny}.' zeny_after='.$c{snapshot}{zeny},
                $s->_pm('VERIFIED '.$s->nonce));
        }
    }
    if ($s->{state} ne 'idle' && $now>$s->{deadline}) {
        if ($s->{state} =~ /^(cancelling|rollback|verifying)$/) {
            $s->_enter('halted');
            return $s->_log('RECONCILIATION_REQUIRED: no retry/payment; reason='.($s->{reason}||'asset mismatch'));
        }
        return $s->abort('TIMEOUT');
    }
    if ($s->{state} eq 'idle') {
        return [] unless $s->{role} eq 'seller' && $c{safe} && $c{peer_near} && @{$c{candidates}||[]};
        $s->{batch}=[map {{%$_}} @{$c{candidates}}[0..($#{$c{candidates}}<9?$#{$c{candidates}}:9)]];
        $s->{nonce}=$s->_new_nonce; $s->{counterpart}=$s->{merchant}; $s->{total}=0;
        $s->{total}+=$s->{policy}->price($_->{nameID})*$_->{amount} for @{$s->{batch}};
        return $s->abort('TOTAL_OVERFLOW') if $s->{total}>1_000_000_000;
        return $s->abort('SELLER_ZENY_OVERFLOW') if $c{snapshot} && $c{snapshot}{zeny}+$s->{total}>2_147_483_647;
        $s->_enter('wait_ready');
        my @messages=($s->_pm('SELL_REQUEST '.$s->nonce.' '.scalar @{$s->{batch}}));
        for my $n (0..$#{$s->{batch}}) {
            my $i=$s->{batch}[$n];
            push @messages,$s->_pm(join(' ','SELL_ITEM',$s->nonce,$n,@$i{qw(nameID amount sig)}));
        }
        return $s->_log('request entries='.scalar(@{$s->{batch}}).' total='.$s->{total},@messages);
    }
    return [] unless $s->{state} =~ /^(engaged|paying|quoted|committing)$/;
    return $s->abort('PEER_MOVED_OR_BUSY') unless $c{peer_near} && $c{trade_safe} && ($c{peer_name}||'') eq $s->counterpart;
    my $other=0+($c{other_zeny}||0);
    if ($s->{role} eq 'seller') {
        return $s->abort('WRONG_QUOTE') if $other && $other!=$s->{total};
        return $s->abort('QUOTE_CHANGED') if $s->{state} ne 'engaged' && $other!=$s->{total};
        return $s->abort('UNEXPECTED_ITEM') if $c{other_item_count};
        if ($s->{state} eq 'engaged' && $s->{sent}==@{$s->{batch}} && $other==$s->{total}) {
            $s->_enter('quoted'); return $s->_log('quote checked',{type=>'finalize'});
        }
    } else {
        return $s->abort('UNEXPECTED_ZENY') if $other;
        if ($s->{state} eq 'engaged' && @{$s->{offered}}==@{$s->{batch}}) {
            my $error=$s->{policy}->capacity($s->{batch},$s->{total},$c{capacity}||{});
            return $s->abort($error) if $error;
            $s->_enter('paying'); return $s->_log('capacity checked; quote total='.$s->{total},{type=>'add_zeny',amount=>$s->{total}});
        }
        if ($s->{state} eq 'paying' && $c{other_finalized}) {
            # rAthena sends Zeny only to the seller, no payer add acknowledgement.
            # The seller locks after checking that authoritative offer.
            my $error=$s->{policy}->capacity($s->{batch},$s->{total},$c{capacity}||{});
            return $s->abort($error) if $error;
            $s->_enter('quoted'); return $s->_log('seller verified quote and locked',{type=>'finalize'});
        }
    }
    if ($s->{state} eq 'quoted' && $c{own_finalized} && $c{other_finalized}) {
        $s->_enter('committing'); return $s->_log('both locked; commit',{type=>'commit'});
    }
    return [];
}
1;
