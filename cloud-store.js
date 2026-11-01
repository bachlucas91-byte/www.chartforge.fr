/* Supabase project storage. Row-level security in supabase/schema.sql controls access. */
(() => {
  'use strict';

  const uuidLike = value => /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(value || ''));
  const cleanBase = config => String(config?.url || '').replace(/\/+$/, '');

  async function request(config, session, table, { method='GET', query={}, body, prefer }={}) {
    if (!config?.url || !config?.key) throw new Error('Connect Supabase in Settings → Account to use shared projects.');
    const url = new URL(`${cleanBase(config)}/rest/v1/${table}`);
    for (const [key, value] of Object.entries(query)) url.searchParams.set(key, String(value));
    const headers = { apikey: config.key };
    if (session?.access_token) headers.Authorization = `Bearer ${session.access_token}`;
    else if (String(config.key).split('.').length === 3) headers.Authorization = `Bearer ${config.key}`;
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    if (prefer) headers.Prefer = prefer;
    let response;
    try {
      response = await fetch(url, { method, headers, ...(body !== undefined ? {body:JSON.stringify(body)} : {}) });
    } catch {
      throw new Error('Could not reach Supabase. Check your connection and try again.');
    }
    const text = await response.text();
    let result = null;
    try { result = text ? JSON.parse(text) : null; } catch { result = text; }
    if (!response.ok) {
      const message = result?.message || result?.details || result?.hint || result?.error || text || 'Supabase request failed.';
      if (/relation .* does not exist|could not find the table|schema cache/i.test(String(message))) {
        throw new Error('Cloud project storage is not set up yet. Run outputs/chartforge/supabase/schema.sql in the Supabase SQL Editor, then try again.');
      }
      if (/row-level security|violates row-level/i.test(String(message))) {
        throw new Error('Supabase blocked this project change. Check that you are signed in and that the project schema is installed.');
      }
      throw new Error(String(message));
    }
    return result;
  }

  function mapProject(row) {
    const dataset = Array.isArray(row.datasets) ? row.datasets[0] : row.datasets;
    const profile = Array.isArray(row.profiles) ? row.profiles[0] : row.profiles;
    const categories = Array.isArray(dataset?.categories) ? dataset.categories : [];
    const rows = Array.isArray(dataset?.rows) ? dataset.rows : [];
    return {
      id:row.id, cloud:true, datasetId:row.dataset_id || dataset?.id || null,
      title:row.title || 'Untitled chart', description:row.description || '',
      chartType:row.chart_type || 'bar-race', config:row.chart_config || {},
      dataset:{timeLabel:dataset?.time_label || 'Time',categories,rows},
      status:row.status || 'draft', visibility:row.visibility || 'private',
      ownerId:row.owner_id, ownerName:profile?.display_name || profile?.username || 'Chart creator',
      createdAt:row.created_at || new Date().toISOString(), updatedAt:row.updated_at || row.created_at || new Date().toISOString(),
      publishedAt:row.published_at || null, views:Number(row.views_count)||0, likes:Number(row.likes_count)||0,
      category:row.category || 'Data stories', hidden:row.status==='hidden'
    };
  }

  const embeddedSelect = '*,datasets(*),profiles!projects_owner_id_fkey(display_name,username)';
  async function listPublic(config, session) {
    const rows = await request(config,session,'projects',{query:{
      select:embeddedSelect, visibility:'eq.public', status:'in.(published,approved)',
      order:'published_at.desc.nullslast,created_at.desc', limit:'200'
    }});
    return (rows || []).map(mapProject);
  }
  async function listOwned(config, session, userId) {
    const rows = await request(config,session,'projects',{query:{
      select:embeddedSelect, owner_id:`eq.${userId}`, order:'updated_at.desc', limit:'500'
    }});
    return (rows || []).map(mapProject);
  }
  async function listLikes(config, session, userId) {
    const rows = await request(config,session,'project_likes',{query:{select:'project_id',user_id:`eq.${userId}`,limit:'1000'}});
    return (rows || []).map(row=>row.project_id);
  }

  async function saveProject(config, session, userId, project, {publish=false}={}) {
    if (!session?.access_token || !userId) throw new Error('Sign in to save projects to your account.');
    const cloudId = project.cloud && uuidLike(project.id) ? project.id : null;
    const oldDatasetId = cloudId ? project.datasetId : null;
    const datasetBody = {
      owner_id:userId, name:project.config?.datasetName || 'Untitled dataset',
      time_label:project.dataset.timeLabel || 'Time', categories:project.dataset.categories, rows:project.dataset.rows
    };
    let datasetId = oldDatasetId;
    let insertedDatasetId = null;
    if (oldDatasetId) {
      await request(config,session,`datasets`,{method:'PATCH',query:{id:`eq.${oldDatasetId}`},body:datasetBody,prefer:'return=minimal'});
    } else {
      const datasets = await request(config,session,'datasets',{method:'POST',query:{select:'id'},body:datasetBody,prefer:'return=representation'});
      datasetId = datasets?.[0]?.id;
      insertedDatasetId = datasetId;
      if (!datasetId) throw new Error('Supabase saved the dataset but did not return its ID. Try again.');
    }
    const now = new Date().toISOString();
    const published = publish || (project.visibility==='public' && project.status==='published');
    const payload = {
      owner_id:userId, dataset_id:datasetId, title:String(project.title||'Untitled chart').trim().slice(0,160) || 'Untitled chart',
      description:project.description || '', chart_type:project.chartType || 'bar-race', chart_config:project.config || {},
      visibility:published?'public':'private', status:published?'published':'draft', category:project.category || 'Data stories',
      published_at:published?(project.publishedAt || now):null
    };
    try {
      const projects = cloudId
        ? await request(config,session,'projects',{method:'PATCH',query:{id:`eq.${cloudId}`,select:embeddedSelect},body:payload,prefer:'return=representation'})
        : await request(config,session,'projects',{method:'POST',query:{select:embeddedSelect},body:payload,prefer:'return=representation'});
      if (!projects?.[0]) throw new Error('Supabase did not return the saved project. Check the table permissions and try again.');
      return mapProject(projects[0]);
    } catch (error) {
      if (insertedDatasetId) {
        try { await request(config,session,'datasets',{method:'DELETE',query:{id:`eq.${insertedDatasetId}`},prefer:'return=minimal'}); } catch {}
      }
      throw error;
    }
  }

  async function deleteProject(config, session, id) {
    const rows = await request(config,session,'projects',{query:{select:'dataset_id',id:`eq.${id}`}});
    await request(config,session,'projects',{method:'DELETE',query:{id:`eq.${id}`},prefer:'return=minimal'});
    const datasetId = rows?.[0]?.dataset_id;
    if (datasetId) { try { await request(config,session,'datasets',{method:'DELETE',query:{id:`eq.${datasetId}`},prefer:'return=minimal'}); } catch {} }
  }
  async function setLiked(config, session, userId, projectId, liked) {
    if (liked) await request(config,session,'project_likes',{method:'POST',body:{project_id:projectId,user_id:userId},prefer:'return=minimal'});
    else await request(config,session,'project_likes',{method:'DELETE',query:{project_id:`eq.${projectId}`,user_id:`eq.${userId}`},prefer:'return=minimal'});
  }
  async function recordView(config, session, projectId, userId=null) {
    await request(config,session,'project_views',{method:'POST',body:{project_id:projectId,viewer_id:userId},prefer:'return=minimal'});
  }
  async function updateProfile(config, session, userId, profile) {
    await request(config,session,'profiles',{method:'PATCH',query:{id:`eq.${userId}`},body:{display_name:profile.name,username:profile.handle,bio:profile.bio||''},prefer:'return=minimal'});
  }

  function mapProfile(row) {
    return {id:row.id,handle:row.username || 'creator',name:row.display_name || row.username || 'Chart creator',bio:row.bio || '',joinedAt:row.created_at || null};
  }
  async function getProfile(config, session, userId) {
    const rows = await request(config,session,'profiles',{query:{select:'id,username,display_name,bio,created_at',id:`eq.${userId}`,limit:'1'}});
    return rows?.[0] ? mapProfile(rows[0]) : null;
  }
  async function listProfiles(config, session) {
    const rows = await request(config,session,'profiles',{query:{select:'id,username,display_name,bio,created_at',order:'display_name.asc,username.asc',limit:'500'}});
    return (rows || []).map(mapProfile);
  }
  async function getFollowSummary(config, session, userId, currentUserId=null) {
    const [followers,following,mine] = await Promise.all([
      request(config,session,'follows',{query:{select:'follower_id',followed_id:`eq.${userId}`,limit:'5000'}}),
      request(config,session,'follows',{query:{select:'followed_id',follower_id:`eq.${userId}`,limit:'5000'}}),
      currentUserId && currentUserId!==userId ? request(config,session,'follows',{query:{select:'follower_id',follower_id:`eq.${currentUserId}`,followed_id:`eq.${userId}`,limit:'1'}}) : Promise.resolve([])
    ]);
    return {followerCount:(followers||[]).length,followingCount:(following||[]).length,isFollowing:Boolean(mine?.length)};
  }
  async function listFollowProfiles(config, session, userId, direction) {
    const followers = direction === 'followers';
    const rows = await request(config,session,'follows',{query:{select:followers?'follower_id':'followed_id',[followers?'followed_id':'follower_id']:`eq.${userId}`,order:'created_at.desc',limit:'1000'}});
    const ids = (rows || []).map(row=>followers?row.follower_id:row.followed_id).filter(uuidLike);
    if (!ids.length) return [];
    const profiles = await request(config,session,'profiles',{query:{select:'id,username,display_name,bio,created_at',id:`in.(${ids.join(',')})`,limit:String(ids.length)}});
    const byId = new Map((profiles || []).map(row=>[row.id,mapProfile(row)]));
    return ids.map(id=>byId.get(id)).filter(Boolean);
  }
  async function ensureProfile(config, session, userId, profile={}) {
    if (!uuidLike(userId)) throw new Error('Your account is not ready yet. Sign out and sign in again.');
    const existing = await request(config,session,'profiles',{query:{select:'id',id:`eq.${userId}`,limit:'1'}});
    if (existing?.[0]) return existing[0];
    const rawBase = String(profile.handle || profile.email?.split('@')[0] || 'creator').toLowerCase().replace(/[^a-z0-9_]/g,'_').replace(/^_+|_+$/g,'') || 'creator';
    const username = `${rawBase.slice(0,21)}_${String(userId).replace(/-/g,'').slice(0,8)}`.slice(0,30);
    const rows = await request(config,session,'profiles',{method:'POST',query:{select:'id'},body:{id:userId,username,display_name:String(profile.name || 'ChartForge creator').slice(0,60)},prefer:'return=representation'});
    return rows?.[0] || {id:userId};
  }
  async function setFollow(config, session, followerId, followedId, following) {
    if (!uuidLike(followerId) || !uuidLike(followedId) || followerId === followedId) throw new Error('Choose another public creator to follow.');
    if (following) await request(config,session,'follows',{method:'POST',body:{follower_id:followerId,followed_id:followedId},prefer:'return=minimal'});
    else await request(config,session,'follows',{method:'DELETE',query:{follower_id:`eq.${followerId}`,followed_id:`eq.${followedId}`},prefer:'return=minimal'});
  }

  window.ChartForgeCloud = { listPublic, listOwned, listLikes, saveProject, deleteProject, setLiked, recordView, updateProfile, getProfile, listProfiles, getFollowSummary, listFollowProfiles, setFollow, ensureProfile };
})();
