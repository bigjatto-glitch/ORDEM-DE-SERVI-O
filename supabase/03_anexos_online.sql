-- Etapa 3. Executar no SQL Editor depois das etapas 1 e 2.
BEGIN;
CREATE OR REPLACE FUNCTION public.bn_register_attachment(p_id text,p_ordem text,p_path text,p_nome text,p_identificado boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE objeto storage.objects; anexo public.bn_anexos; tamanho bigint; mime text;
BEGIN
 IF auth.uid() IS NULL OR NOT big_norte_private.pode_ver_os(p_ordem) THEN RAISE EXCEPTION 'Sem acesso à OS.' USING ERRCODE='42501'; END IF;
 IF length(p_id) NOT BETWEEN 1 AND 100 OR split_part(p_path,'/',1) IS DISTINCT FROM p_ordem OR length(trim(p_nome))=0 THEN RAISE EXCEPTION 'Identificação do arquivo inválida.'; END IF;
 SELECT * INTO objeto FROM storage.objects WHERE bucket_id='big-norte-os' AND name=p_path;
 IF objeto.id IS NULL OR objeto.owner_id IS DISTINCT FROM auth.uid()::text THEN RAISE EXCEPTION 'Envie o arquivo antes de confirmar o anexo.'; END IF;
 tamanho=coalesce((objeto.metadata->>'size')::bigint,(objeto.metadata->>'contentLength')::bigint,0);
 mime=coalesce(objeto.metadata->>'mimetype','');
 IF tamanho<=0 OR tamanho>52428800 OR (mime NOT LIKE 'image/%' AND mime NOT LIKE 'video/%') THEN RAISE EXCEPTION 'Arquivo inválido ou maior que 50 MB.'; END IF;
 SELECT * INTO anexo FROM public.bn_anexos WHERE id=p_id;
 IF anexo.id IS NOT NULL THEN
  IF anexo.ordem_id IS DISTINCT FROM p_ordem OR anexo.arquivo_path IS DISTINCT FROM p_path OR anexo.criado_por<>auth.uid() THEN RAISE EXCEPTION 'Identificador de anexo já utilizado.'; END IF;
  RETURN to_jsonb(anexo);
 END IF;
 INSERT INTO public.bn_anexos(id,ordem_id,arquivo_path,nome,mime,tamanho,criado_por,identificacao_aplicada)
 VALUES(p_id,p_ordem,p_path,p_nome,mime,tamanho,auth.uid(),p_identificado) RETURNING * INTO anexo;
 RETURN to_jsonb(anexo);
END $$;
CREATE OR REPLACE FUNCTION public.bn_remove_attachment(p_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE anexo public.bn_anexos;
BEGIN
 IF auth.uid() IS NULL OR big_norte_private.perfil_atual() IS NULL THEN RAISE EXCEPTION 'Entre na sua conta.' USING ERRCODE='42501'; END IF;
 SELECT * INTO anexo FROM public.bn_anexos WHERE id=p_id FOR UPDATE;
 IF anexo.id IS NULL THEN RETURN jsonb_build_object('removido',true); END IF;
 IF NOT big_norte_private.pode_ver_os(anexo.ordem_id) OR (big_norte_private.perfil_atual()='motorista' AND anexo.criado_por<>auth.uid()) THEN RAISE EXCEPTION 'Sem permissão para remover o anexo.' USING ERRCODE='42501'; END IF;
 IF EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='big-norte-os' AND name=anexo.arquivo_path) THEN RAISE EXCEPTION 'Remova o arquivo pelo serviço de armazenamento primeiro.'; END IF;
 DELETE FROM public.bn_anexos WHERE id=p_id;
 RETURN jsonb_build_object('removido',true);
END $$;
REVOKE ALL ON FUNCTION public.bn_register_attachment(text,text,text,text,boolean),public.bn_remove_attachment(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.bn_register_attachment(text,text,text,text,boolean),public.bn_remove_attachment(text) TO authenticated;
DROP POLICY IF EXISTS bn_arquivos_remover ON storage.objects;
CREATE POLICY bn_arquivos_remover ON storage.objects FOR DELETE TO authenticated
USING(bucket_id='big-norte-os' AND big_norte_private.pode_ver_os(split_part(name,'/',1)) AND
 (big_norte_private.perfil_atual() IN ('admin','administrativo') OR owner_id=auth.uid()::text));
DROP POLICY IF EXISTS bn_motorista_auxiliar ON public.bn_colaboradores;
CREATE POLICY bn_motorista_auxiliar ON public.bn_colaboradores FOR SELECT TO authenticated
USING(big_norte_private.perfil_atual()='motorista' AND EXISTS(
 SELECT 1 FROM public.bn_equipes e WHERE e.motorista_id=big_norte_private.colaborador_atual() AND e.auxiliar_id=bn_colaboradores.id
));
-- Relatórios usam a data de execução informada pelo aparelho quando disponível.
-- A numeração continua sendo atribuída na confirmação pelo servidor.
CREATE OR REPLACE FUNCTION big_norte_private.exportar(tipo text,r jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path='' AS $export$
DECLARE v jsonb; instante timestamptz;
BEGIN
 v=coalesce(r->'dados','{}'::jsonb)||jsonb_build_object('id',r->>'id','_version',(r->>'versao')::bigint);
 IF tipo='ordens' THEN
  v=v-'numeroOficial'-'concluidaEm';
  v=v||jsonb_build_object('status',r->>'status');
  IF r->>'numero_oficial' IS NOT NULL THEN v=v||jsonb_build_object('numeroOficial',r->>'numero_oficial'); END IF;
  IF r->>'concluida_em' IS NOT NULL THEN
   instante=(r->>'concluida_em')::timestamptz;
   IF nullif(r->'dados'->>'concluidaEmLocal','') IS NOT NULL THEN
    BEGIN instante=(r->'dados'->>'concluidaEmLocal')::timestamptz;
    EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN instante=(r->>'concluida_em')::timestamptz;
    END;
   END IF;
   v=v||jsonb_build_object('concluidaEm',(instante AT TIME ZONE 'America/Fortaleza')::date::text);
  END IF;
 END IF;
 RETURN v;
END $export$;
REVOKE ALL ON FUNCTION big_norte_private.exportar(text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION big_norte_private.exportar(text,jsonb) TO authenticated;
COMMIT;
SELECT 'Etapa 3 criada: fotos e vídeos privados prontos para sincronização.' AS resultado;
