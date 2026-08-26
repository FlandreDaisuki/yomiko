#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${MOCK_REVIEW_ARGS_PATH:-}" ]]; then
  printf '%s\n' "$*" >>"${MOCK_REVIEW_ARGS_PATH}"
fi

case "${1:-} ${2:-}" in
"variants reviews")
  case "${MOCK_REVIEW_RESULT:-success}" in
  malformed) printf '{not-json\n' ;;
  failure) printf 'private list failure\n' >&2; exit 7 ;;
  *)
    jq -cn '{actionable_count:1,reviews:[{
      id:7,review_type:"candidate_identity",source_gid:101,candidate_gid:102,
      covered_review_count:1,source_class_size:1,candidate_class_size:1,
      status:"pending",decision:null,selected_gid:null,evidence:{components:[],contradictions:[]},
      source:{gid:101,token:"source-token",title:"Source",thumb:"https://example.test/source.jpg",file_count:10,category:"Manga",expunged:false},
      candidate:{gid:102,token:"candidate-token",title:"Candidate",thumb:"https://example.test/candidate.jpg",file_count:11,category:"Manga",expunged:false},
      choices:[]
    }]}'
    ;;
  esac
  ;;
"variants resolve")
  case "${MOCK_REVIEW_RESULT:-success}" in
  malformed) printf '[]\n' ;;
  stale) exit 3 ;;
  failure) printf 'private resolve failure\n' >&2; exit 7 ;;
  *)
    jq -cn --argjson review_id "${3}" '{resolved:true,review_id:$review_id,review_type:"candidate_identity",decision:"same_book",source_gid:101,candidate_gid:102,selected_gid:null,evaluation_created:false,reevaluation_queued:true,merged_group:false,reviews_collapsed:0,groups_unblocked:1}'
    ;;
  esac
  ;;
*)
  printf 'unexpected command: %s\n' "$*" >&2
  exit 9
  ;;
esac
