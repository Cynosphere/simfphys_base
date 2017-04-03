AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
include("shared.lua")
include("spawn.lua")
include("simfunc.lua")
include("numpads.lua")

function ENT:Think()
	local Time = CurTime()
	if IsValid( self.DriverSeat ) then
		local Driver = self.DriverSeat:GetDriver()
		if self:GetDriver() ~= Driver then
			self:SetDriver( Driver )
			self:SetActive( IsValid( Driver ) )
		end
	end
	
	if self:IsInitialized() then
		self:SetColors()
		self:SimulateVehicle( Time )
		self:ControlLighting( Time )
		self:ControlExFx()
		
		self.NextWaterCheck = self.NextWaterCheck or 0
		if self.NextWaterCheck < Time then
			self.NextWaterCheck = Time + 0.2
			self:WaterPhysics()
		end
		
		if self:GetActive() then
			self:SetPhysics( ((math.abs(self.ForwardSpeed) < 50) and (self.Brake > 0 or self.HandBrake > 0)) )
		else
			self:SetPhysics( true )
		end
	end
	
	self:NextThink(Time + 0.025)
	
	return true
end

function ENT:OnActiveChanged( name, old, new)
	if new == old then return end
	
	if not self:IsInitialized() then return end
	
	local TurboCharged = self:GetTurboCharged()
	local SuperCharged = self:GetSuperCharged()
	
	if new == true then
		self.HandBrakePower = self:GetMaxTraction() + 20 - self:GetTractionBias() * self:GetMaxTraction()
		
		if self:GetEMSEnabled() then
			if self.ems then
				self.ems:Play()
			end
		end
		
		if TurboCharged then
			self.Turbo = CreateSound(self, self.snd_spool or "simulated_vehicles/turbo_spin.wav")
			self.Turbo:PlayEx(0,0)
		end
		
		if SuperCharged then
			self.Blower = CreateSound(self, self.snd_bloweroff or "simulated_vehicles/blower_spin.wav")
			self.BlowerWhine = CreateSound(self, self.snd_bloweron or "simulated_vehicles/blower_gearwhine.wav")
			
			self.Blower:PlayEx(0,0)
			self.BlowerWhine:PlayEx(0,0)
		end
		
		local ply = self:GetDriver()
		if IsValid( ply ) then
			self:SetupControls( ply )
			
			if ply:GetInfoNum( "cl_simfphys_autostart", 1 ) > 0 then 
				self:StartEngine()
			end
		else
			self:StartEngine()
		end
	else
		self:StopEngine()

		self.IsLocked = false
		
		if self.ems then
			self.ems:Stop()
		end

		if self.horn then
			self.horn:Stop()
		end
		
		if TurboCharged then
			self.Turbo:Stop()
		end

		if SuperCharged then
			self.Blower:Stop()
			self.BlowerWhine:Stop()
		end
		
		if self.PressedKeys then
			for k,v in pairs( self.PressedKeys ) do
				self.PressedKeys[k] = false
			end
		end
		
		if self.keys then
			for i = 1, table.Count( self.keys ) do
				numpad.Remove( self.keys[i] )
			end
		end
		
		self:SetIsBraking( false )
		self:SetGear( 2 )
	end
	
	if istable( self.Wheels ) then
		for i = 1, table.Count( self.Wheels ) do
			local Wheel = self.Wheels[ i ]
			if IsValid(Wheel) then
				Wheel:SetOnGround( 0 )
			end
		end
	end
end

function ENT:OnThrottleChanged( name, old, new)
	if new == old then return end
	
	local Health = self:GetCurHealth()
	local MaxHealth = self:GetMaxHealth()
	local Active = self:EngineActive()
	
	if new == 1 then
		if Health < MaxHealth * 0.6 then
			if Active then
				if math.Round(math.random(0,4),0) == 1 then
					self:DamagedStall()
				end
			end
		end
	end
	
	if new == 0 then
		if self:GetTurboCharged() then
			if (self.SmoothTurbo > 350) then
				local Volume = math.Clamp( ((self.SmoothTurbo - 300) / 150) ,0, 1) * 0.5
				self.SmoothTurbo = 0
				self.BlowOff:Stop()
				self.BlowOff = CreateSound(self, self.snd_blowoff or "simulated_vehicles/turbo_blowoff.ogg")
				self.BlowOff:PlayEx(Volume,100)
			end
		end
	end
end

function ENT:WaterPhysics()
	if self:WaterLevel() <= 1 then self.IsInWater = false return end
	
	if self:GetDoNotStall() then 
		
		self:SetOnFire( false )
		self:SetOnSmoke( false )
		
		return
	end
	
	if not self.IsInWater then
		if self:EngineActive() then
			self:EmitSound( "vehicles/jetski/jetski_off.wav" )
		end
		
		self.IsInWater = true
		self.EngineIsOn = 0
		self.EngineRPM = 0
		self:SetFlyWheelRPM( 0 )
		
		self:SetOnFire( false )
		self:SetOnSmoke( false )
	end
	
	local phys = self:GetPhysicsObject()
	phys:ApplyForceCenter( -self:GetVelocity() * 0.5 * phys:GetMass() )
end

function ENT:SetColors()
	if self.ColorableProps then
		
		local Color = self:GetColor()
		local dot = Color.r * Color.g * Color.b * Color.a
		
		if dot ~= self.OldColor then
			
			for i, prop in pairs( self.ColorableProps ) do
				if IsValid(prop) then
					prop:SetColor( Color )
					prop:SetRenderMode( self:GetRenderMode() )
				end
			end
			
			self.OldColor = dot
		end
	end
end

function ENT:ControlLighting( curtime )
	
	if (self.NextLightCheck or 0) < curtime then
		
		if self.LightsActivated ~= self.DoCheck then
			self.DoCheck = self.LightsActivated
			
			if self.LightsActivated then
				self:SetLightsEnabled(true)
			end
		end
	end
end

function ENT:GetEngineData()
	local LimitRPM = math.max(self:GetLimitRPM(),4)
	local Powerbandend = math.Clamp(self:GetPowerBandEnd(),3,LimitRPM - 1)
	local Powerbandstart = math.Clamp(self:GetPowerBandStart(),2,Powerbandend - 1)
	local IdleRPM = math.Clamp(self:GetIdleRPM(),1,Powerbandstart - 1)
	local Data = {
		IdleRPM = IdleRPM,
		Powerbandstart = Powerbandstart,
		Powerbandend = Powerbandend,
		LimitRPM = LimitRPM,
	}
	return Data
end

function ENT:SimulateVehicle( curtime )
	local Active = self:GetActive()
	
	local EngineData = self:GetEngineData()
	
	local LimitRPM = EngineData.LimitRPM
	local Powerbandend = EngineData.Powerbandend
	local Powerbandstart = EngineData.Powerbandstart
	local IdleRPM = EngineData.IdleRPM
	
	self.Forward =  self:LocalToWorldAngles( self.VehicleData.LocalAngForward ):Forward() 
	self.Right = self:LocalToWorldAngles( self.VehicleData.LocalAngRight ):Forward() 
	self.Up = self:GetUp()
	
	self.Vel = self:GetVelocity()
	self.VelNorm = self.Vel:GetNormalized()
	
	self.MoveDir = math.acos( math.Clamp( self.Forward:Dot(self.VelNorm) ,-1,1) ) * (180 / math.pi)
	self.ForwardSpeed = math.cos(self.MoveDir * (math.pi / 180)) * self.Vel:Length()
	
	if self.poseon then
		self.cpose = self.cpose or self.LightsPP.min
		local anglestep = math.abs(math.max(self.LightsPP.max or self.LightsPP.min)) / 3
		self.cpose = self.cpose + math.Clamp(self.poseon - self.cpose,-anglestep,anglestep)
		self:SetPoseParameter(self.LightsPP.name, self.cpose)
	end
	
	self:SetPoseParameter("vehicle_guage", (math.abs(self.ForwardSpeed) * 0.0568182 * 0.75) / (self.SpeedoMax or 120))
	
	if self.RPMGaugePP then
		local flywheelrpm = self:GetFlyWheelRPM()
		local rpm
		if self:GetRevlimiter() then
			local throttle = self:GetThrottle()
			local maxrpm = self:GetLimitRPM()
			local revlimiter = (maxrpm > 2500) and (throttle > 0)
			rpm = math.Round(((flywheelrpm >= maxrpm - 200) and revlimiter) and math.Round(flywheelrpm - 200 + math.sin(curtime * 50) * 600,0) or flywheelrpm,0)
		else
			rpm = flywheelrpm
		end
	
		self:SetPoseParameter(self.RPMGaugePP,  rpm / self.RPMGaugeMax)
	end
	
	
	if Active then
		local ply = self:GetDriver()
		local IsValidDriver = IsValid( ply )
		
		local GearUp = self.PressedKeys["M1"] and 1 or 0
		local GearDown = self.PressedKeys["M2"] and 1 or 0
		
		local W = self.PressedKeys["W"] and 1 or 0
		local A = self.PressedKeys["A"] and 1 or 0
		local S = self.PressedKeys["S"] and 1 or 0
		local D = self.PressedKeys["D"] and 1 or 0
		
		if IsValidDriver then self:PlayerSteerVehicle( ply, A, D ) end
		
		local aW = self.PressedKeys["aW"] and 1 or 0
		local aA = self.PressedKeys["aA"] and 1 or 0
		local aS = self.PressedKeys["aS"] and 1 or 0
		local aD = self.PressedKeys["aD"] and 1 or 0
		
		local cruise = self:GetIsCruiseModeOn()
		
		local k_sanic = IsValidDriver and ply:GetInfoNum( "cl_simfphys_sanic", 0 ) or 1
		local sanicmode = isnumber( k_sanic ) and k_sanic or 0
		local k_Shift = self.PressedKeys["Shift"]
		local Shift = (sanicmode == 1) and (k_Shift and 0 or 1) or (k_Shift and 1 or 0)
		
		local sportsmode = IsValidDriver and ply:GetInfoNum( "cl_simfphys_sport", 0 ) or 1
		local k_auto = IsValidDriver and ply:GetInfoNum( "cl_simfphys_auto", 0 ) or 1
		local transmode = (k_auto == 1)
		
		local Alt = self.PressedKeys["Alt"] and 1 or 0
		local Space = self.PressedKeys["Space"] and 1 or 0
		
		if cruise then
			if k_Shift then
				self.cc_speed = math.Round(self:GetVelocity():Length(),0) + 70
			end
			if Alt == 1 then
				self.cc_speed = math.Round(self:GetVelocity():Length(),0) - 25
			end
		end
		
		self:SimulateTransmission(W,S,Shift,Alt,Space,GearUp,GearDown,transmode,IdleRPM,Powerbandstart,Powerbandend,sportsmode,cruise,curtime)
		
		self:SimulateEngine( IdleRPM, LimitRPM, Powerbandstart, Powerbandend, curtime )
		self:SimulateWheels( math.max(Space,Alt), LimitRPM )
		self:SimulateAirControls( aW, aS, aA, aD )
		
		if self.WheelOnGroundDelay < curtime then
			self:WheelOnGround()
			self.WheelOnGroundDelay = curtime + 0.15
		end
	end
	
	if self.CustomWheels then
		self:PhysicalSteer()
	end
end

function ENT:ControlExFx()
	if not self.ExhaustPositions then return end
	
	local IsOn = self:GetActive()
	
	self.EnableExFx = (math.abs(self.ForwardSpeed) <= 420) and (self.EngineIsOn == 1) and IsOn
	self.CheckExFx = self.CheckExFx or false
	
	if self.CheckExFx ~= self.EnableExFx then
		self.CheckExFx = self.EnableExFx
		
		if self.EnableExFx then
			
			for i = 1, table.Count( self.ExhaustPositions ) do
				
				local Fx = self.exfx[i]
				
				if (IsValid(Fx)) then
					if (self.ExhaustPositions[i].OnBodyGroups) then
						if (self:BodyGroupIsValid( self.ExhaustPositions[i].OnBodyGroups )) then
							Fx:Fire( "Start" )
						end
					else
						Fx:Fire( "Start" )
					end
				end
			end
			
		else
			for i = 1, table.Count( self.ExhaustPositions ) do
				
				local Fx = self.exfx[i]
				
				if IsValid(Fx) then
					Fx:Fire( "Stop" )
				end
			end
		end
	end
end

function ENT:BodyGroupIsValid( bodygroups )
	
	for index, groups in pairs( bodygroups ) do
		
		local mygroup = self:GetBodygroup( index )
		
		for g_index = 1, table.Count( groups ) do
			if mygroup == groups[g_index] then return true end
		end
	end
	
	return false
end

function ENT:SetupControls( ply )

	if self.keys then
		for i = 1, table.Count( self.keys ) do
			numpad.Remove( self.keys[i] )
		end
	end

	if IsValid(ply) then
		self.cl_SteerSettings = {
			Overwrite = (ply:GetInfoNum( "cl_simfphys_overwrite", 0 ) >= 1),
			TurnSpeed = ply:GetInfoNum( "cl_simfphys_steerspeed", 8 ),
			fadespeed = ply:GetInfoNum( "cl_simfphys_fadespeed", 535 ),
			fastspeedangle = ply:GetInfoNum( "cl_simfphys_steerangfast", 10 ),
		}
		
		local W = ply:GetInfoNum( "cl_simfphys_keyforward", 0 )
		local A = ply:GetInfoNum( "cl_simfphys_keyleft", 0 )
		local S = ply:GetInfoNum( "cl_simfphys_keyreverse", 0 )
		local D = ply:GetInfoNum( "cl_simfphys_keyright", 0 )
		
		local aW = ply:GetInfoNum( "cl_simfphys_key_air_forward", 0 )
		local aA = ply:GetInfoNum( "cl_simfphys_key_air_left", 0 )
		local aS = ply:GetInfoNum( "cl_simfphys_key_air_reverse", 0 )
		local aD = ply:GetInfoNum( "cl_simfphys_key_air_right", 0 )
		
		local GearUp = ply:GetInfoNum( "cl_simfphys_keygearup", 0 )
		local GearDown = ply:GetInfoNum( "cl_simfphys_keygeardown", 0 )
		
		local R = ply:GetInfoNum( "cl_simfphys_cruisecontrol", 0 )
		
		local F = ply:GetInfoNum( "cl_simfphys_lights", 0 )
		
		local V = ply:GetInfoNum( "cl_simfphys_foglights", 0 )
		
		local H = ply:GetInfoNum( "cl_simfphys_keyhorn", 0 )
		
		local I = ply:GetInfoNum( "cl_simfphys_keyengine", 0 )
		
		local Shift = ply:GetInfoNum( "cl_simfphys_keywot", 0 )
		
		local Alt = ply:GetInfoNum( "cl_simfphys_keyclutch", 0 )
		local Space = ply:GetInfoNum( "cl_simfphys_keyhandbrake", 0 )
		
		local lock = ply:GetInfoNum( "cl_simfphys_key_lock", 0 )
		
		local w_dn = numpad.OnDown( ply, W, "k_forward",self, true )
		local w_up = numpad.OnUp( ply, W, "k_forward",self, false )
		local s_dn = numpad.OnDown( ply, S, "k_reverse",self, true )
		local s_up = numpad.OnUp( ply, S, "k_reverse",self, false )
		local a_dn = numpad.OnDown( ply, A, "k_left",self, true )
		local a_up = numpad.OnUp( ply, A, "k_left",self, false )
		local d_dn = numpad.OnDown( ply, D, "k_right",self, true )
		local d_up = numpad.OnUp( ply, D, "k_right",self, false )
		
		local aw_dn = numpad.OnDown( ply, aW, "k_a_forward",self, true )
		local aw_up = numpad.OnUp( ply, aW, "k_a_forward",self, false )
		local as_dn = numpad.OnDown( ply, aS, "k_a_reverse",self, true )
		local as_up = numpad.OnUp( ply, aS, "k_a_reverse",self, false )
		local aa_dn = numpad.OnDown( ply, aA, "k_a_left",self, true )
		local aa_up = numpad.OnUp( ply, aA, "k_a_left",self, false )
		local ad_dn = numpad.OnDown( ply, aD, "k_a_right",self, true )
		local ad_up = numpad.OnUp( ply, aD, "k_a_right",self, false )
		
		local gup_dn = numpad.OnDown( ply, GearUp, "k_gup",self, true )
		local gup_up = numpad.OnUp( ply, GearUp, "k_gup",self, false )
		
		local gdn_dn = numpad.OnDown( ply, GearDown, "k_gdn",self, true )
		local gdn_up = numpad.OnUp( ply, GearDown, "k_gdn",self, false )
		
		local shift_dn = numpad.OnDown( ply, Shift, "k_wot",self, true )
		local shift_up = numpad.OnUp( ply, Shift, "k_wot",self, false )
		
		local alt_dn = numpad.OnDown( ply, Alt, "k_clutch",self, true )
		local alt_up = numpad.OnUp( ply, Alt, "k_clutch",self, false )
		
		local space_dn = numpad.OnDown( ply, Space, "k_hbrk",self, true )
		local space_up = numpad.OnUp( ply, Space, "k_hbrk",self, false )
		
		local k_cruise = numpad.OnDown( ply, R, "k_ccon",self, true )
		
		local k_lights_dn = numpad.OnDown( ply, F, "k_lgts",self, true )
		local k_lights_up = numpad.OnUp( ply, F, "k_lgts",self, false )
		
		local k_flights_dn = numpad.OnDown( ply, V, "k_flgts",self, true )
		local k_flights_up = numpad.OnUp( ply, V, "k_flgts",self, false )
		
		local k_horn_dn = numpad.OnDown( ply, H, "k_hrn",self, true )
		local k_horn_up = numpad.OnUp( ply, H, "k_hrn",self, false )
		
		local k_engine_dn = numpad.OnDown( ply, I, "k_eng",self, true )
		local k_engine_up = numpad.OnUp( ply, I, "k_eng",self, false )
		
		local k_lock_dn = numpad.OnDown( ply, lock, "k_lock",self, true )
		local k_lock_up = numpad.OnUp( ply, lock, "k_lock",self, false )
		
		self.keys = {
			w_dn,w_up,
			s_dn,s_up,
			a_dn,a_up,
			d_dn,d_up,
			aw_dn,aw_up,
			as_dn,as_up,
			aa_dn,aa_up,
			ad_dn,ad_up,
			gup_dn,gup_up,
			gdn_dn,gdn_up,
			shift_dn,shift_up,
			alt_dn,alt_up,
			space_dn,space_up,
			k_cruise,
			k_lights_dn,k_lights_up,
			k_horn_dn,k_horn_up,
			k_flights_dn,k_flights_up,
			k_engine_dn,k_engine_up,
			k_lock_dn,k_lock_up,
		}
	end
end

function ENT:PlayAnimation( animation )
	local anims = string.Implode( ",", self:GetSequenceList() )
	
	if not animation or not string.match( string.lower(anims), string.lower( animation ), 1 ) then return end
	
	local sequence = self:LookupSequence( animation )
	
	self:ResetSequence( sequence )
	self:SetPlaybackRate( 1 ) 
	self:SetSequence( sequence )
end

function ENT:PhysicalSteer()
	
	if IsValid(self.SteerMaster) then
		local physobj = self.SteerMaster:GetPhysicsObject()
		if not IsValid(physobj) then return end
		
		if physobj:IsMotionEnabled() then
			physobj:EnableMotion(false)
		end
		
		self.SteerMaster:SetAngles( self:LocalToWorldAngles( Angle(0,math.Clamp(-self.VehicleData[ "Steer" ],-self.CustomSteerAngle,self.CustomSteerAngle),0) ) )
	end
	
	if IsValid(self.SteerMaster2) then
		local physobj = self.SteerMaster2:GetPhysicsObject()
		if not IsValid(physobj) then return end
		
		if physobj:IsMotionEnabled() then
			physobj:EnableMotion(false)
		end
		
		self.SteerMaster2:SetAngles( self:LocalToWorldAngles( Angle(0,math.Clamp(self.VehicleData[ "Steer" ],-self.CustomSteerAngle,self.CustomSteerAngle),0) ) )
	end
end

function ENT:IsInitialized()
	return (self.EnableSuspension == 1)
end

function ENT:EngineActive()
	return (self.EngineIsOn == 1)
end

function ENT:IsDriveWheelsOnGround()
	return (self.DriveWheelsOnGround == 1)
end

function ENT:GetRPM()
	local RPM = self.EngineRPM and self.EngineRPM or 0
	return RPM
end

function ENT:GetDiffGear()
	return math.max(self:GetDifferentialGear(),0.01)
end

function ENT:DamagedStall()
	if not self:GetActive() then return end
	
	local rtimer = 0.8
	
	timer.Simple( rtimer, function()
		if not IsValid(self) then return end
		net.Start( "simfphys_backfire" )
			net.WriteEntity( self )
		net.Broadcast()
	end)
	
	self:StallAndRestart( rtimer, true )
end

function ENT:StopEngine()
	if self:EngineActive() then
		self:EmitSound( "vehicles/jetski/jetski_off.wav" )
	end

	self.EngineRPM = 0
	self.EngineIsOn = 0
	
	self:SetFlyWheelRPM( 0 )
	self:SetIsCruiseModeOn( false )
end

function ENT:StartEngine( bIgnoreSettings )
	if not bIgnoreSettings then
		self.CurrentGear = 2
	end
		
	if not self.IsInWater then
		self.EngineRPM = self:GetEngineData().IdleRPM
		self.EngineIsOn = 1
	else
		if self:GetDoNotStall() then
			self.EngineRPM = self:GetEngineData().IdleRPM
			self.EngineIsOn = 1
		end
	end
end

function ENT:StallAndRestart( nTimer, bIgnoreSettings )
	nTimer = nTimer or 1
	
	self:StopEngine()
	
	local ply = self:GetDriver()
	if IsValid(ply) and not bIgnoreSettings then
		if ply:GetInfoNum( "cl_simfphys_autostart", 1 ) <= 0 then return end
	end
	
	timer.Simple( nTimer, function()
		if not IsValid(self) then return end
		self:StartEngine( bIgnoreSettings )
	end)
end

function ENT:PlayerSteerVehicle( ply, left, right )
	if IsValid(ply) then
		local CounterSteeringEnabled = (ply:GetInfoNum( "cl_simfphys_ctenable", 0 ) or 1) == 1
		local CounterSteeringMul =  math.Clamp(ply:GetInfoNum( "cl_simfphys_ctmul", 0 ) or 0.7,0.1,2)
		local MaxHelpAngle = math.Clamp(ply:GetInfoNum( "cl_simfphys_ctang", 0 ) or 15,1,90)
		
		local Ang = self.MoveDir
		
		local TurnSpeed
		local fadespeed
		local fastspeedangle
		
		if self.cl_SteerSettings.Overwrite then
			TurnSpeed = self.cl_SteerSettings.TurnSpeed
			fadespeed = self.cl_SteerSettings.fadespeed
			fastspeedangle = self.cl_SteerSettings.fastspeedangle
		else
			TurnSpeed = self:GetSteerSpeed()
			fadespeed = self:GetFastSteerConeFadeSpeed()
			fastspeedangle = self:GetFastSteerAngle() * self.VehicleData["steerangle"]
		end
		
		local SlowSteeringRate = (Ang > 20) and ((math.Clamp((self.ForwardSpeed - 150) / 25,0,1) == 1) and 60 or self.VehicleData["steerangle"]) or self.VehicleData["steerangle"]
		local FastSteeringAngle = math.Clamp(fastspeedangle,1,SlowSteeringRate)
		
		local FastSteeringRate = FastSteeringAngle + ((Ang > (FastSteeringAngle-1)) and 1 or 0) * math.min(Ang,90 - FastSteeringAngle)
		
		local Ratio = 1 - math.Clamp((math.abs(self.ForwardSpeed) - fadespeed) / 25,0,1)
		
		local SteerRate = FastSteeringRate + (SlowSteeringRate - FastSteeringRate) * Ratio
		local Steer = ((left + right) > 0 and (right - left) or self:GetMouseSteer()) * SteerRate
		
		local LocalDrift = math.acos( math.Clamp( self.Right:Dot(self.VelNorm) ,-1,1) ) * (180 / math.pi) - 90
		
		local CounterSteer = CounterSteeringEnabled and (math.Clamp(LocalDrift * CounterSteeringMul * (((left + right) == 0) and 1 or 0),-MaxHelpAngle,MaxHelpAngle) * ((self.ForwardSpeed > 50) and 1 or 0)) or 0
		
		self.SmoothAng = self.SmoothAng + math.Clamp((Steer - CounterSteer) - self.SmoothAng,-TurnSpeed,TurnSpeed)
		
		self:SteerVehicle( self.SmoothAng )
	end
end

function ENT:SteerVehicle( steer )
	self.VehicleData[ "Steer" ] = steer
	self:SetVehicleSteer( steer / self.VehicleData["steerangle"] )
end

function ENT:Lock()
	self.IsLocked = true
end

function ENT:UnLock()
	self.IsLocked = false
end

function ENT:ForceLightsOff()
	local vehiclelist = list.Get( "simfphys_lights" )[self.LightsTable] or false
	if not vehiclelist then return end
	
	if vehiclelist.Animation then
		if self.LightsActivated then
			self.LightsActivated = false
			self.LampsActivated = false
			
			self:SetLightsEnabled(false)
			self:SetLampsEnabled(false)
		end
	end
end

function ENT:EnteringSequence( ply )
	local LinkedDoorAnims = istable(self.ModelInfo) and istable(self.ModelInfo.LinkDoorAnims)
	if not istable(self.Enterpoints) and not LinkedDoorAnims then return end
	
	local sequence
	local pos
	local dist
	
	if LinkedDoorAnims then
		for i,_ in pairs( self.ModelInfo.LinkDoorAnims ) do
			local seq_ = self.ModelInfo.LinkDoorAnims[ i ].enter
			
			local a_pos = self:GetAttachment( self:LookupAttachment( i ) ).Pos
			local a_dist = (ply:GetPos() - a_pos):Length()
			
			if not sequence then
				sequence = seq_
				pos = a_pos
				dist = a_dist
			else
				if a_dist < dist then
					sequence = seq_
					pos = a_pos
					dist = a_dist
				end
			end
		end
	else
		for i = 1, table.Count( self.Enterpoints ) do
			local a_ = self.Enterpoints[ i ]
			
			local a_pos = self:GetAttachment( self:LookupAttachment( a_ ) ).Pos
			local a_dist = (ply:GetPos() - a_pos):Length()
			
			if i == 1 then
				sequence = a_
				pos = a_pos
				dist = a_dist
			else
				if  (a_dist < dist) then
					sequence = a_
					pos = a_pos
					dist = a_dist
				end
			end
		end
	end
	
	self:PlayAnimation( sequence )
	self:ForceLightsOff()
end

function ENT:GetMouseSteer()
	if IsValid(self.DriverSeat) then return (self.DriverSeat.ms_Steer or 0) end
	
	return 0
end

function ENT:Use( ply )
	if self.IsLocked then 
		self:EmitSound( "doors/default_locked.wav" )
		return
	end
	
	if not IsValid(self:GetDriver()) and not ply:KeyDown(IN_WALK) then
		ply:SetAllowWeaponsInVehicle( false ) 
		if IsValid(self.DriverSeat) then
			
			self:EnteringSequence( ply )
			ply:EnterVehicle( self.DriverSeat )
			
			timer.Simple( 0.01, function()
				if IsValid(ply) then
					local angles = Angle(0,90,0)
					ply:SetEyeAngles( angles )
				end
			end)
		end
	else
		if self.PassengerSeats then
			local closestSeat = self:GetClosestSeat( ply )
			
			if not closestSeat or IsValid( closestSeat:GetDriver() ) then
				
				for i = 1, table.Count( self.pSeat ) do
					if IsValid(self.pSeat[i]) then
						
						local HasPassenger = IsValid(self.pSeat[i]:GetDriver())
						
						if not HasPassenger then
							ply:EnterVehicle( self.pSeat[i] )
							break
						end
					end
				end
			else
				ply:EnterVehicle( closestSeat )
			end
		end
	end
end

function ENT:GetClosestSeat( ply )
	local Seat = self.pSeat[1]
	if not IsValid(Seat) then return false end
	
	local Distance = (Seat:GetPos() - ply:GetPos()):Length()
	
	for i = 1, table.Count( self.pSeat ) do
		local Dist = (self.pSeat[i]:GetPos() - ply:GetPos()):Length()
		if (Dist < Distance) then
			Seat = self.pSeat[i]
		end
	end
	
	return Seat
end

function ENT:SetPhysics( enable )
	if enable then
		if not self.PhysicsEnabled then
			for i = 1, table.Count( self.Wheels ) do
				local Wheel = self.Wheels[i]
				if IsValid(Wheel) then
					Wheel:GetPhysicsObject():SetMaterial("jeeptire")
				end
			end
			self.PhysicsEnabled = true
		end
	else
		if self.PhysicsEnabled ~= false then
			for i = 1, table.Count( self.Wheels ) do
				local Wheel = self.Wheels[i]
				if IsValid(Wheel) then
					Wheel:GetPhysicsObject():SetMaterial("friction_00")
				end
			end
			self.PhysicsEnabled = false
		end
	end
end

function ENT:SetSuspension( index , bIsDamaged )
	local bIsDamaged = bIsDamaged or false
	
	local h_mod = index <= 2 and self:GetFrontSuspensionHeight() or self:GetRearSuspensionHeight()
	
	local heights = {
		[1] = self.FrontHeight + self.VehicleData.suspensiontravel_fl * -h_mod,
		[2] = self.FrontHeight + self.VehicleData.suspensiontravel_fl * -h_mod,
		[3] = self.RearHeight + self.VehicleData.suspensiontravel_rl * -h_mod,
		[4] = self.RearHeight + self.VehicleData.suspensiontravel_rr * -h_mod,
		[5] = self.RearHeight + self.VehicleData.suspensiontravel_rl * -h_mod,
		[6] = self.RearHeight + self.VehicleData.suspensiontravel_rr * -h_mod
	}
	local Wheel = self.Wheels[index]
	if not IsValid(Wheel) then return end
	
	local subRadius = bIsDamaged and Wheel.dRadius or 0
	
	local newheight = heights[index] + subRadius

	local Elastic = self.Elastics[index]
	if IsValid(Elastic) then
		Elastic:Fire( "SetSpringLength", newheight )
	end
	
	if self.StrengthenSuspension == true then
		local Elastic2 = self.Elastics[index * 10]
		if IsValid(Elastic2) then
			Elastic2:Fire( "SetSpringLength", newheight )
		end
	end
end

function ENT:OnFrontSuspensionHeightChanged( name, old, new )
	if old == new then return end
	if not self.CustomWheels and new > 0 then new = 0 end
	if not self:IsInitialized() then return end
	
	if IsValid(self.Wheels[1]) then
		local Elastic = self.Elastics[1]
		if IsValid(Elastic) then
			Elastic:Fire( "SetSpringLength", self.FrontHeight + self.VehicleData.suspensiontravel_fl * -new )
		end
		
		if self.StrengthenSuspension == true then
			
			local Elastic2 = self.Elastics[10]
			
			if IsValid(Elastic2) then
				Elastic2:Fire( "SetSpringLength", self.FrontHeight + self.VehicleData.suspensiontravel_fl * -new )
			end
		end
	end
	
	if IsValid(self.Wheels[2]) then
		local Elastic = self.Elastics[2]
		if IsValid(Elastic) then
			Elastic:Fire( "SetSpringLength", self.FrontHeight + self.VehicleData.suspensiontravel_fr * -new )
		end
		
		if self.StrengthenSuspension == true then
			
			local Elastic2 = self.Elastics[20]
			
			if (IsValid(Elastic2)) then
				Elastic2:Fire( "SetSpringLength", self.FrontHeight + self.VehicleData.suspensiontravel_fr * -new )
			end
		end
	end
end

function ENT:OnRearSuspensionHeightChanged( name, old, new )
	if old == new then return end
	if not self.CustomWheels and new > 0 then new = 0 end
	if not self:IsInitialized() then return end
	
	if IsValid(self.Wheels[3]) then
		local Elastic = self.Elastics[3]
		if IsValid(Elastic) then
			Elastic:Fire( "SetSpringLength", self.RearHeight + self.VehicleData.suspensiontravel_rl * -new )
		end
		
		if self.StrengthenSuspension == true then
			
			local Elastic2 = self.Elastics[30]
			
			if IsValid(Elastic2) then
				Elastic2:Fire( "SetSpringLength", self.RearHeight + self.VehicleData.suspensiontravel_rl * -new )
			end
		end
	end
	
	if IsValid(self.Wheels[4]) then
		local Elastic = self.Elastics[4]
		if IsValid(Elastic) then
			Elastic:Fire( "SetSpringLength", self.RearHeight + self.VehicleData.suspensiontravel_rr * -new )
		end
		
		if self.StrengthenSuspension == true then
			
			local Elastic2 = self.Elastics[40]
			
			if IsValid(Elastic2) then
				Elastic2:Fire( "SetSpringLength", self.RearHeight + self.VehicleData.suspensiontravel_rr * -new )
			end
		end
	end
	
	if IsValid(self.Wheels[5]) then
		local Elastic = self.Elastics[5]
		if IsValid(Elastic) then
			Elastic:Fire( "SetSpringLength", self.RearHeight + self.VehicleData.suspensiontravel_rl * -new )
		end
		
		if self.StrengthenSuspension == true then
			
			local Elastic2 = self.Elastics[50]
			
			if IsValid(Elastic2) then
				Elastic2:Fire( "SetSpringLength", self.RearHeight + self.VehicleData.suspensiontravel_rl * -new )
			end
		end
	end
	
	if IsValid(self.Wheels[6]) then
		local Elastic = self.Elastics[6]
		if IsValid(Elastic) then
			Elastic:Fire( "SetSpringLength", self.RearHeight + self.VehicleData.suspensiontravel_rr * -new )
		end
		
		if self.StrengthenSuspension == true then
			
			local Elastic2 = self.Elastics[60]
			
			if IsValid(Elastic2) then
				Elastic2:Fire( "SetSpringLength", self.RearHeight + self.VehicleData.suspensiontravel_rr * -new )
			end
		end
	end
end

function ENT:OnTurboCharged( name, old, new )
	if old == new then return end
	local Active = self:GetActive()
	
	if new == true and Active then
		self.Turbo:Stop()
		self.Turbo = CreateSound(self, self.snd_spool or "simulated_vehicles/turbo_spin.wav")
		self.Turbo:PlayEx(0,0)
		
	elseif new == false then
		if self.Turbo then
			self.Turbo:Stop()
		end
	end
end

function ENT:OnSuperCharged( name, old, new )
	if old == new then return end
	local Active = self:GetActive()
	
	if new == true and Active then
		self.Blower:Stop()
		self.BlowerWhine:Stop()
		
		self.Blower = CreateSound(self, self.snd_bloweroff or "simulated_vehicles/blower_spin.wav")
		self.BlowerWhine = CreateSound(self, self.snd_bloweron or "simulated_vehicles/blower_gearwhine.wav")
	
		self.Blower:PlayEx(0,0)
		self.BlowerWhine:PlayEx(0,0)
	elseif new == false then
		if self.Blower then
			self.Blower:Stop()
		end
		if self.BlowerWhine then
			self.BlowerWhine:Stop()
		end
	end
end

function ENT:OnRemove()
	if self.Wheels then
		for i = 1, table.Count( self.Wheels ) do
			local Ent = self.Wheels[ i ]
			if IsValid(Ent) then
				Ent:Remove()
			end
		end
	end
	if self.keys then
		for i = 1, table.Count( self.keys ) do
			numpad.Remove( self.keys[i] )
		end
	end
	if self.Turbo then
		self.Turbo:Stop()
	end
	if self.Blower then
		self.Blower:Stop()
	end
	if self.BlowerWhine then
		self.BlowerWhine:Stop()
	end
	if self.horn then
		self.horn:Stop()
	end
	if self.ems then
		self.ems:Stop()
	end
end

function ENT:PlayPP( On )
	self.poseon = On and self.LightsPP.max or self.LightsPP.min
end

function ENT:GetEnginePos()
	local Attachment = self:GetAttachment( self:LookupAttachment( "vehicle_engine" ) )
	local pos = self:GetPos()
	if Attachment then
		pos = Attachment.Pos
	end
	if isvector(self.EnginePos) then
		pos = self:LocalToWorld( self.EnginePos )
	end
	
	return pos
end

function ENT:DamageLoop()
	if not self.IamOnFire then return end
	
	local CurHealth = self:GetNWFloat( "Health", 0 )
	
	if CurHealth <= 0 then return end
	
	self:TakeDamage(1, Entity(0), Entity(0) )
	
	timer.Simple( 0.15, function()
		if IsValid(self) then
			self:DamageLoop()
		end
	end)
end

function ENT:SetOnFire( bOn )
	if bOn == self.IamOnFire then return end
	self.IamOnFire = bOn
	
	if bOn then
		if not IsValid(self.EngineFire) then
			local pos = self:GetEnginePos()
			local ang = isvector(self.Forward) and self.Forward:Angle() or Angle(0,0,0)
		
			self.EngineFire = ents.Create( "info_particle_system" )
			self.EngineFire:SetKeyValue( "effect_name" , "burning_engine_01")
			self.EngineFire:SetKeyValue( "start_active" , 1)
			self.EngineFire:SetOwner( self )
			self.EngineFire:SetPos( pos )
			self.EngineFire:SetAngles( ang )
			self.EngineFire:Spawn()
			self.EngineFire:Activate()
			self.EngineFire:SetParent( self )
			self.EngineFire.DoNotDuplicate = true
			self.EngineFire:EmitSound( "ambient/fire/mtov_flame2.wav" )
			
			self:s_MakeOwner( self.EngineFire )
			
			self.EngineFire.snd = CreateSound(self, "ambient/fire/fire_small1.wav")
			self.EngineFire.snd:Play()
			
			self.EngineFire:CallOnRemove( "stopdemfiresounds", function( vehicle )
				if IsValid(self.EngineFire) then
					if self.EngineFire.snd then
						self.EngineFire.snd:Stop()
					end
				end
			end)
			
			self:DamagedStall()
			self:DamageLoop()
		end
	else
		if IsValid(self.EngineFire) then
			if self.EngineFire.snd then
				self.EngineFire.snd:Stop()
			end
			self.EngineFire:Remove()
			self.EngineFire = nil
		end
	end
end

function ENT:SetOnSmoke( bOn )
	if bOn == self.IamOnSmoke then return end
	self.IamOnSmoke = bOn
	
	if bOn then
		if not IsValid(self.EngineSmoke) then
			local pos = self:GetEnginePos()
			local ang = isvector(self.Forward) and self.Forward:Angle() or Angle(0,0,0)
			
			self.EngineSmoke = ents.Create( "info_particle_system" )
			self.EngineSmoke:SetKeyValue( "effect_name" , "smoke_gib_01")
			self.EngineSmoke:SetKeyValue( "start_active" , 1)
			self.EngineSmoke:SetOwner( self )
			self.EngineSmoke:SetPos( pos )
			self.EngineSmoke:SetAngles( ang )
			self.EngineSmoke:Spawn()
			self.EngineSmoke:Activate()
			self.EngineSmoke:SetParent( self )
			self.EngineSmoke.DoNotDuplicate = true
			self:s_MakeOwner( self.EngineSmoke )
			
			self.EngineSmoke.snd = CreateSound(self, "ambient/gas/steam2.wav")
			self.EngineSmoke.snd:PlayEx(0.2,90)
			
			self.EngineSmoke:CallOnRemove( "stopdemsmokesounds", function( vehicle )
				if IsValid(self.EngineSmoke) then
					if self.EngineSmoke.snd then
						self.EngineSmoke.snd:Stop()
					end
				end
			end)
			
			self:DamagedStall()
		end
	else
		if IsValid(self.EngineSmoke) then
			if self.EngineSmoke.snd then
				self.EngineSmoke.snd:Stop()
			end
			self.EngineSmoke:Remove()
			self.EngineSmoke = nil
		end
	end
end

function ENT:s_MakeOwner( entity )
	if CPPI then
		if (IsValid( self.EntityOwner )) then
			entity:CPPISetOwner( self.EntityOwner )
		end
	end
end
