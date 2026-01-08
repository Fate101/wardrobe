
if engine.ActiveGamemode() ~= "terrortown" then
	return
end

-- TTT Extension for Wardrobe
-- Handles queueing model changes during active rounds and applying them staggered when safe.

wardrobe.ttt = wardrobe.ttt or {}
wardrobe.ttt.queue = wardrobe.ttt.queue or {}

print("Wardrobe | Loaded TTT extension!")

-- ConVar to enable/disable ghost models (Server Controlled)
local cv_ghosts = CreateConVar("wardrobe_ttt_ghosts", "1", {FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY}, "Enable/Disable TTT hitbox visualization ghosts")

local function IsRoundActive()
	return GetRoundState() == ROUND_ACTIVE
end

-- Hook to block and queue model changes during active rounds
hook.Add("Wardrobe_RecieveModel", "wardrobe.ttt", function(ply, wsid, mdl)
	-- If the round is active, we block the change and queue it
	if IsRoundActive() then
		wardrobe.ttt.queue[ply] = {wsid, mdl}
		
		-- Notify the player
		ply:ChatPrint("Wardrobe | Your model change has been queued for the next round.")
		print("Wardrobe | Queued model change for " .. ply:Nick())
		
		return false
	end
end)

-- Function to apply queued models with staggering
local function ProcessQueue()
	if table.Count(wardrobe.ttt.queue) == 0 then return end
	
	print("Wardrobe | Processing TTT model queue...")
	
	local delay = 0
	local staggerTime = 0.2 -- Seconds between each application
	
	for ply, data in pairs(wardrobe.ttt.queue) do
		-- Check if player is still valid
		if IsValid(ply) then
			timer.Simple(delay, function()
				if IsValid(ply) then
					-- data[1] = wsid, data[2] = mdl
					if SERVER then
						wardrobe.setModel(ply, data[1], data[2])
					else
						-- Client side setModel expects (ply, mdl, wsid)
						wardrobe.setModel(ply, data[2], data[1])
					end
					ply:ChatPrint("Wardrobe | Applied queued model.")
					print("Wardrobe | Applied queued model for " .. ply:Nick())
				end
			end)
			delay = delay + staggerTime
		end
	end
	
	wardrobe.ttt.queue = {}
end

-- Process queue on round prepare and end
hook.Add("TTTPrepareRound", "wardrobe.ttt", ProcessQueue)
hook.Add("TTTEndRound", "wardrobe.ttt", ProcessQueue)




-- Clean up queue on disconnect
hook.Add("PlayerDisconnected", "wardrobe.ttt", function(ply)
	wardrobe.ttt.queue[ply] = nil
end)

if CLIENT then
	-- Hitbox Visualization
	-- Renders a subtle ghost of the original model over the custom model to show true hitboxes.
	
	local ghostModels = {}
	
	local function SafeRemoveGhost(ply)
		if ghostModels[ply] then
			SafeRemoveEntity(ghostModels[ply])
			ghostModels[ply] = nil
		end
	end
	
	hook.Add("PostPlayerDraw", "wardrobe.ttt.visuals", function(ply)
		-- Check server setting
		if not cv_ghosts:GetBool() then
			SafeRemoveGhost(ply)
			return
		end

		-- Only render if they have a custom wardrobe model
		if not (ply.wardrobe and IsValid(ply)) then 
			SafeRemoveGhost(ply)
			return 
		end
		
		-- Do not render on dead players / ragdolls
		if not ply:Alive() or ply:GetObserverMode() ~= OBS_MODE_NONE then
			SafeRemoveGhost(ply)
			return
		end
		
		-- Do not render on ourselves in first person (unless we are in third person)
		if ply == LocalPlayer() and GetViewEntity() == LocalPlayer() and not LocalPlayer():ShouldDrawLocalPlayer() then
			SafeRemoveGhost(ply)
			return
		end
		
		-- Create ghost if needed
		local ghost = ghostModels[ply]
		local desiredModel = ply.originalModel or "models/player/phoenix.mdl" -- Fallback if original not stored (should be stored by wardrobe)
		if not desiredModel or desiredModel == "" then desiredModel = "models/player/phoenix.mdl" end
		
		if not IsValid(ghost) or ghost:GetModel() ~= desiredModel then
			SafeRemoveGhost(ply)
			
			ghost = ClientsideModel(desiredModel)
			if IsValid(ghost) then
				ghost:SetNoDraw(true) -- We draw it manually
				ghostModels[ply] = ghost
			end
		end
		
		if IsValid(ghost) then
			-- Sync position and angles to the player
			ghost:SetPos(ply:GetPos())
			ghost:SetAngles(ply:GetRenderAngles()) -- Use RenderAngles to match smooth visual rotation
			
			-- Sync animation state
			-- We must translate the sequence via Activity, because different models have different sequence IDs
			-- e.g. Sequence 5 might be 'Run' on one model but 'Swim' on another.
			local act = ply:GetSequenceActivity(ply:GetSequence())
			if act ~= -1 then
				local ghostSeq = ghost:SelectWeightedSequence(act)
				if ghostSeq ~= -1 then
					ghost:SetSequence(ghostSeq)
				else
					ghost:SetSequence(0) -- Idk, fallback
				end
			else
				-- Fallback if no activity found (custom sequence), maybe try direct map or just idle
				ghost:SetSequence(0)
			end
			
			ghost:SetCycle(ply:GetCycle())
			ghost:SetPlaybackRate(ply:GetPlaybackRate())
			
			-- Sync pose parameters (aiming, looking, etc.)
			-- This is crucial for head hitboxes
			for i = 0, ply:GetNumPoseParameters() - 1 do
				local name = ply:GetPoseParameterName(i)
				ghost:SetPoseParameter(name, ply:GetPoseParameter(name))
			end
			
			-- Force sync aim_pitch based on EyeAngles (Fixes internal model not Looking Up/Down)
			-- This is necessary because some custom models might not have standard aim_pitch parameters to copy from.
			local eyeAngles = ply:EyeAngles()
			local yawDiff = math.NormalizeAngle(eyeAngles.y - ghost:GetAngles().y)
			
			ghost:SetPoseParameter("aim_pitch", math.NormalizeAngle(eyeAngles.p))
			ghost:SetPoseParameter("head_pitch", math.NormalizeAngle(eyeAngles.p)) -- Some models use this
			
			ghost:SetPoseParameter("aim_yaw", yawDiff)
			ghost:SetPoseParameter("head_yaw", yawDiff)
			
			-- Ensure bones are setup
			ghost:SetupBones()
			
			-- Render the ghost with low opacity
			-- VISIBILITY CHECK:
			-- Use a TraceLine with MASK_SHOT to ensure we catch props and walls.
			-- We check the WorldSpaceCenter (approx chest/stomach) to see if the body is visible.
			-- If the body is hidden behind a prop, we hide the ghost to avoid "leg wallhacks".
			-- This is stricter than EyePos, as usually the body is the larger target.
			
			local tr = util.TraceLine({
				start = LocalPlayer():GetShootPos(), -- Use ShootPos to match gun alignment
				endpos = ply:WorldSpaceCenter(),
				filter = {LocalPlayer(), ply}, -- Ignore self and target
				mask = MASK_SHOT
			})
			
			-- Only draw if we hit nothing (fraction == 1.0) or we are very close
			if not tr.Hit then
				render.SetBlend(0.2)
				render.SetColorModulation(1, 1, 1) 
				
				cam.IgnoreZ(true)
				ghost:DrawModel()
				cam.IgnoreZ(false)
				
				render.SetBlend(1)
			end
		end
	end)
	
	-- Cleanup when players assume full physics or become invalid
	-- Note: PostPlayerDraw manages creation/deletion safely, but we should cleanup on disconnect too.
	-- Since "ghostModels" keys are player entities, they will be invalidated automatically by Lua GC weak keys... 
	-- wait, keys are not weak here. We need manual cleanup.
	
	hook.Add("EntityRemoved", "wardrobe.ttt.visuals_cleanup", function(ent)
		if ghostModels[ent] then
			SafeRemoveGhost(ent)
		end
	end)
end
